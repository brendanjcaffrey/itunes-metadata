require_relative 'test_helper'
require 'rack/mock'
require_relative '../server'

class ServerTest < AnalysisTest
  def setup
    super
    @app = Class.new(Server)
    @app.set :analysis_queue, @queue
    @app.set :environment, :test
    @app.set :show_exceptions, false
    @app.set :raise_errors, false
    @request = Rack::MockRequest.new(->(env) { @app.call(env.merge('HTTP_HOST' => 'localhost')) })
  end

  def test_status_endpoint_and_main_view_show_analysis_and_preserve_safe_track_descriptions
    cache(A)
    @library.tracks = [@library.tracks.first]
    @library.tracks.first.desc = '<Artist> & Track'
    response = @request.get('/api/status')
    assert_equal 200, response.status
    assert_equal 'no-store', response['cache-control']
    status = JSON.parse(response.body)
    assert_equal 1, status['analyzed']
    assert_equal A, status['tracks'].first['id']
    assert_equal 120, status['tracks'].first['bpm']

    response = @request.get('/')
    assert_equal 200, response.status
    assert_includes response.body, '&lt;Artist&gt; &amp; Track'
    assert_includes response.body, 'id="analysis-status"'
    assert_includes response.body, "fetch('/api/status'"
  end

  def test_cold_audio_and_analysis_endpoints_work_without_visiting_track_page
    @library.tracks = [@library.tracks.first]
    response = @request.get("/audio/#{A.downcase}")
    assert_equal 200, response.status
    assert_equal 'audio/wav', response['content-type']
    assert_equal 'decoded audio', response.body

    response = @request.get("/waveform/#{A}.dat")
    assert_equal 200, response.status
    assert_equal 'waveform data', response.body

    response = @request.get("/beats/#{A}.json")
    assert_equal 200, response.status
    assert_includes response['content-type'], 'application/json'
    assert_nil JSON.parse(response.body)['bpm']
    assert_equal [A], @analyzer.calls
  end

  def test_original_mp3_is_served_in_full_without_waiting_for_analysis
    @library.tracks = [@library.tracks.first]
    @library.source = File.join(@root, 'original with spaces.MP3')
    File.write(@library.source, 'original MP3 bytes')
    @analyzer.hold(A)
    @queue.start
    assert_equal A, next_started

    response = @request.get("/audio/#{A.downcase}")
    assert_equal 200, response.status
    assert_equal 'audio/mpeg', response['content-type']
    assert_equal 'original MP3 bytes', response.body
    assert_equal response.body.bytesize, response['content-length'].to_i
    refute File.exist?(@analyzer.paths(A)[:audio])
  end

  def test_original_mp3_is_preferred_over_cached_wav
    cache(A)
    @library.tracks = [@library.tracks.first]
    @library.source = File.join(@root, 'original.mp3')
    File.write(@library.source, 'original MP3 bytes')

    response = @request.get("/audio/#{A}")
    assert_equal 200, response.status
    assert_equal 'audio/mpeg', response['content-type']
    assert_equal 'original MP3 bytes', response.body
    assert_empty @analyzer.calls
    assert_equal 'cached audio', File.read(@analyzer.paths(A)[:audio])
  end

  def test_missing_mp3_falls_back_to_cached_wav
    cache(A)
    @library.tracks = [@library.tracks.first]
    @library.source = File.join(@root, 'missing.mp3')

    response = @request.get("/audio/#{A}")
    assert_equal 200, response.status
    assert_equal 'audio/wav', response['content-type']
    assert_equal 'cached audio', response.body
  end

  def test_audio_download_script_is_served
    response = @request.get('/audio-download.js')
    assert_equal 200, response.status
    assert_includes response['content-type'], 'application/javascript'
    assert_equal File.read(File.expand_path('../audio-download.js', __dir__)), response.body
  end

  def test_unknown_tracks_return_json_404
    response = @request.get('/beats/0123456789ABCDEF.json')
    assert_equal 404, response.status
    assert_equal 'Track is not in the playlist', JSON.parse(response.body)['error']

    response = @request.get('/audio/0123456789ABCDEF')
    assert_equal 404, response.status
    refute_includes @library.lookups, '0123456789ABCDEF'
  end

  def test_tool_failure_returns_json_503_with_retry_after
    @library.tracks = [@library.tracks.first]
    @analyzer.failure = A
    response = @request.get("/audio/#{A}")
    assert_equal 503, response.status
    assert_equal '3', response['retry-after']
    assert_equal 'tool failed', JSON.parse(response.body)['error']
  end

  def test_track_page_prioritizes_without_waiting_for_analysis
    @analyzer.hold(A)
    @queue.start
    assert_equal A, next_started
    track = Track.new('Name', 'Artist', 'Album', 'Artist', 'House', '2026', '1', '1', '1', '1', '0', '120', '0', '120', [])
    Library.stub(:get_track, track) do
      response = @request.get("/track/#{C}")
      assert_equal 200, response.status
      assert_includes response.body, "/audio/#{C}"
      refute_match(/<audio\b[^>]*\bsrc=/, response.body)
      assert_match(/id="play-pause" disabled/, response.body)
    end
    assert_equal [C, B], @queue.status[:queue]
  end

  def test_track_submission_immediately_updates_main_view_and_status_cache
    files = cache(A)
    @library.tracks = [@library.tracks.first]
    saved = []
    Library.stub(:set_track_info, ->(id, track) { saved << [id, track] }) do
      response = @request.post("/track/#{A.downcase}", params: { name: 'New Title', artist: 'New Artist' })
      assert_equal 303, response.status
      assert_equal '/', URI.parse(response['location']).path
    end

    assert_equal A, saved.first.first
    assert_equal 'New Title', saved.first.last.name
    response = @request.get('/')
    assert_includes response.body, 'New Artist - New Title'
    status = JSON.parse(@request.get('/api/status').body)
    assert_equal 'New Artist - New Title', status['tracks'].first['description']
    assert_equal 'analyzed', status['tracks'].first['state']
    assert_empty @analyzer.calls
    assert_equal 'cached audio', File.read(files[:audio])
  end

  def test_failed_track_submission_preserves_cached_description
    cache(A)
    @library.tracks = [@library.tracks.first]
    Library.stub(:set_track_info, ->(*) { raise 'Music update failed' }) do
      response = @request.post("/track/#{A}", params: { name: 'Unsaved Title', artist: 'Unsaved Artist' })
      assert_equal 500, response.status
    end
    status = JSON.parse(@request.get('/api/status').body)
    assert_equal "Track #{A}", status['tracks'].first['description']
  end
end
