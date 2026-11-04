require_relative 'test_helper'

class AnalysisQueueTest < AnalysisTest
  def test_saved_metadata_survives_an_older_in_flight_playlist_refresh
    @queue.refresh
    snapshot_read = Queue.new
    finish_refresh = Queue.new
    @library.define_singleton_method(:get_playlist_tracks) do |_|
      snapshot = tracks.map(&:dup)
      snapshot_read << true
      finish_refresh.pop
      snapshot
    end

    refresh = Thread.new { @queue.refresh }
    Timeout.timeout(5) { snapshot_read.pop }
    update = Thread.new { @queue.update_track(A, Track.new('New Title', 'New Artist')) }
    eventually { update.status == 'sleep' || !update.alive? }
    finish_refresh << true
    [refresh, update].each { |thread| Timeout.timeout(5) { thread.value } }

    assert_equal 'New Artist - New Title', @queue.playlist_tracks.first.desc
    assert_equal 'New Artist - New Title', @queue.status[:tracks].first[:description]
  ensure
    finish_refresh << true if finish_refresh
    [refresh, update].compact.each(&:join)
  end

  def test_startup_analyzes_playlist_and_reuses_cache_across_restarts_and_tag_changes
    files = cache(A)
    @queue.start
    eventually { @queue.status[:analyzed] == 3 }
    assert_equal [B, C], @analyzer.calls
    assert_equal 'cached audio', File.read(files[:audio])
    assert_equal [B, C], @library.lookups
    @queue.stop

    File.write(@source, 'changed tags')
    @library.tracks.first.desc = 'Updated metadata'
    @queue = build_queue
    @queue.start
    assert_equal 3, @queue.status[:analyzed]
    assert_equal 'Updated metadata', @queue.status[:tracks].first[:description]
    assert_equal [B, C], @analyzer.calls
    assert_equal [B, C], @library.lookups
  end

  def test_requests_prioritize_and_deduplicate_waiting_work
    @analyzer.hold(A)
    @queue.start
    assert_equal A, next_started
    3.times { @queue.prioritize(C) }
    assert_equal [C, B], @queue.status[:queue]

    requests = [:audio, :waveform, :beats].map do |artifact|
      Thread.new { @queue.wait_for(C, artifact) }
    end
    @analyzer.release_all
    requests.each { |request| assert File.size?(Timeout.timeout(5) { request.value }) }
    eventually { @queue.status[:analyzed] == 3 }
    assert_equal [A, C, B], @analyzer.calls
    assert_nil @queue.status[:tracks].find { |track| track[:id] == C }[:bpm]
    assert @queue.status[:tracks].find { |track| track[:id] == C }[:beats]
  end

  def test_refresh_removes_queued_tracks_and_cleans_active_tracks_after_they_finish
    cache(A, complete: false)
    cache(B, complete: false)
    artwork = File.join(@root, 'artwork', "#{B}_0.jpg")
    File.write(artwork, 'cover')
    marker = File.join(@root, 'audio', '.gitkeep')
    File.write(marker, '')
    @analyzer.hold(A)
    @queue.start
    assert_equal A, next_started

    @library.tracks = [@library.tracks.last]
    @queue.refresh
    assert_equal [C], @queue.status[:queue]
    assert File.exist?(@analyzer.paths(A)[:audio]), 'active inputs must remain until work finishes'
    refute File.exist?(@analyzer.paths(B)[:audio])
    refute File.exist?(artwork)
    assert_raises(AnalysisQueue::NotFound) { @queue.wait_for(A, :audio) }
    @analyzer.release_all
    eventually { @queue.status[:analyzed] == 1 && @queue.status[:active].nil? }
    assert_equal [A, C], @analyzer.calls
    @analyzer.paths(A).each_value { |path| refute File.exist?(path) }
    assert File.exist?(marker)
  end

  def test_failed_playlist_read_preserves_previous_snapshot_and_caches
    files = cache(A)
    @library.tracks = [@library.tracks.first]
    @queue.start
    @library.refresh_error = 'Music unavailable'
    @queue.refresh
    assert_equal [A], @queue.playlist_tracks.map(&:id)
    assert_equal 'Music unavailable', @queue.status[:refresh_error]
    assert File.exist?(files[:audio])

    @library.refresh_error = nil
    @library.tracks = []
    @queue.refresh
    assert_nil @queue.status[:refresh_error]
    assert_empty @queue.playlist_tracks
    files.each_value { |path| refute File.exist?(path) }
  end

  def test_removed_active_track_can_be_readded_before_analysis_finishes
    original_tracks = @library.tracks
    @analyzer.hold(A)
    @queue.start
    assert_equal A, next_started
    @library.tracks = []
    @queue.refresh
    @library.tracks = original_tracks
    @queue.refresh
    assert_equal 'analyzing', @queue.status[:tracks].first[:state]
    @analyzer.release_all
    eventually { @queue.status[:analyzed] == 3 }
    assert @analyzer.complete?(A)
    assert_equal 1, @analyzer.calls.count(A)
  end

  def test_background_timer_refreshes_playlist_while_analysis_is_busy
    @queue = build_queue(refresh_interval: 0.03)
    @analyzer.hold(A)
    @queue.start
    assert_equal A, next_started
    @library.tracks = [@library.tracks.last]
    eventually { @queue.playlist_tracks.map(&:id) == [C] }
    assert_equal A, @queue.status[:active]
    assert_equal [C], @queue.status[:queue]
  end

  def test_failed_startup_read_keeps_existing_caches_and_recovers_on_refresh
    files = cache(A)
    @library.refresh_error = 'Music unavailable at startup'
    @queue.start
    assert_equal 'Music unavailable at startup', @queue.status[:refresh_error]
    assert_empty @queue.playlist_tracks
    files.each_value { |path| assert File.exist?(path) }
    @library.refresh_error = nil
    @queue.refresh
    eventually { @queue.status[:analyzed] == 3 }
    refute_includes @library.lookups, A
  end

  def test_analysis_failure_wakes_request_and_worker_continues
    @analyzer.failure = A
    @queue.start
    error = assert_raises(AnalysisQueue::Unavailable) { @queue.wait_for(A, :beats) }
    assert_equal 'tool failed', error.message
    eventually { @queue.status[:analyzed] == 2 }
    assert_equal 1, @queue.status[:failed]
    @analyzer.failure = nil
    @queue.prioritize(A)
    eventually { @queue.status[:analyzed] == 3 }
  end

  def test_waiting_requests_timeout_and_unknown_tracks_are_rejected
    @analyzer.hold(A)
    @queue.start
    assert_equal A, next_started
    assert_raises(AnalysisQueue::Unavailable) { @queue.wait_for(A, :beats, timeout: 0.01) }
    assert_raises(AnalysisQueue::NotFound) { @queue.prioritize('../source') }
  end

  def test_partial_cache_resumes_only_missing_stages_and_replaces_corrupt_beats
    @library.tracks = [@library.tracks.first]
    files = cache(A, complete: false)
    File.write(files[:beats], '{invalid json')
    File.write(File.join(@root, 'beats', "#{A}.tmp.json"), 'interrupted output')
    @queue.start
    eventually { @queue.status[:analyzed] == 1 }
    assert_empty @library.lookups
    assert_equal %w[aubiotrack aubio], @analyzer.commands.map(&:first)
    assert_equal 'cached audio', File.read(files[:audio])
    assert_nil JSON.parse(File.read(files[:beats]))['bpm']
    refute File.exist?(File.join(@root, 'beats', "#{A}.tmp.json"))
  end

  def test_artifact_is_available_while_later_stages_are_still_queued
    files = cache(C, complete: false)
    @analyzer.hold(A)
    @queue.start
    assert_equal A, next_started
    assert_equal files[:audio], @queue.wait_for(C, :audio, timeout: 0.01)
    assert_equal [C, B], @queue.status[:queue]
  end
end
