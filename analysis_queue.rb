require 'thread'
require 'time'
require_relative 'track_analysis'

# One analysis worker avoids duplicate conversions and keeps CPU/disk work
# bounded. Playlist polling has its own thread so it continues during analysis.
class AnalysisQueue
  class NotFound < StandardError; end
  class Unavailable < StandardError; end

  def initialize(playlist_id:, library:, root: __dir__, refresh_interval: 60, analyzer: nil)
    @playlist_id = playlist_id
    @library = library
    @analyzer = analyzer || TrackAnalysis.new(root: root, library: library)
    @refresh_interval = Float(refresh_interval)
    raise ArgumentError, 'Refresh interval must be positive' unless @refresh_interval.positive?

    @mutex = Mutex.new
    @lifecycle = Mutex.new
    @refresh_mutex = Mutex.new
    @changed = ConditionVariable.new
    @tracks = []
    @states = {}
    @queue = []
    @running = false
  end

  def start
    @lifecycle.synchronize do
      return self if @running

      @mutex.synchronize { @running = true }
      refresh
      @worker = Thread.new { work }
      @refresher = Thread.new { poll }
    end
    self
  end

  def stop
    @lifecycle.synchronize do
      @mutex.synchronize do
        @running = false
        @changed.broadcast
      end
      [@worker, @refresher].compact.each(&:join)
    end
  end

  def playlist_tracks
    @mutex.synchronize { @tracks.dup }
  end

  def update_track(id, track)
    # Apply after any in-flight playlist read, so an older snapshot cannot
    # overwrite metadata that was just saved by a request.
    @refresh_mutex.synchronize do
      @mutex.synchronize do
        index = @tracks.index { |cached| cached.id == id }
        return unless index

        cached = @tracks[index].dup
        cached.desc = "#{track.artist} - #{track.name}"
        @tracks[index] = cached
      end
    end
  end

  def refresh
    @refresh_mutex.synchronize do
      tracks = @library.get_playlist_tracks(@playlist_id).uniq(&:id)
      @mutex.synchronize do
        ids = tracks.map(&:id)
        @analyzer.cleanup(ids + [@active].compact)
        @tracks = tracks
        @states.delete_if { |id, _| !ids.include?(id) }
        @queue.select! { |id| ids.include?(id) }
        ids.each do |id|
          if id == @active
            @states[id] ||= { state: @active_stage, error: nil }
            next
          end

          if @analyzer.complete?(id)
            @states[id] = { state: 'analyzed', error: nil }
            @queue.delete(id)
          else
            @states[id] = { state: 'queued', error: nil }
            @queue << id unless @queue.include?(id)
          end
        end
        @last_refreshed_at = Time.now.utc.iso8601
        @refresh_error = nil
        @changed.broadcast
      end
    end
  rescue StandardError => error
    @mutex.synchronize { @refresh_error = error.message }
    warn "Playlist refresh failed: #{error.message}"
  end

  def prioritize(id)
    @mutex.synchronize { prioritize_locked(id) }
  end

  def playback_file(id)
    prioritize(id)
    source, = @library.get_track_location_and_duration(id)
    return source if File.extname(source).downcase == '.mp3' && File.file?(source) && File.size?(source)

    wait_for(id, :audio)
  end

  # Requests wait for their artifact, not for unrelated stages or the entire
  # playlist. Errors and timeouts become HTTP responses instead of infinite waits.
  def wait_for(id, artifact, timeout: 300)
    deadline = monotonic_time + timeout
    @mutex.synchronize do
      prioritize_locked(id)
      loop do
        raise NotFound, 'Track is no longer in the playlist' unless @states.key?(id)
        return @analyzer.paths(id).fetch(artifact) if @analyzer.artifacts(id).fetch(artifact)
        raise Unavailable, @states[id][:error] if @states[id][:state] == 'failed'
        raise Unavailable, 'Analysis worker is stopped' unless @running

        remaining = deadline - monotonic_time
        raise Unavailable, 'Track analysis is still in progress; please retry' if remaining <= 0

        @changed.wait(@mutex, remaining)
      end
    end
  end

  def status
    @mutex.synchronize do
      tracks = @tracks.map do |track|
        { id: track.id, description: track.desc }.merge(@states.fetch(track.id)).merge(@analyzer.artifacts(track.id))
      end
      {
        total: tracks.size,
        analyzed: tracks.count { |track| track[:state] == 'analyzed' },
        queued: @queue.size,
        failed: tracks.count { |track| track[:state] == 'failed' },
        active: @active,
        queue: @queue.dup,
        tracks: tracks,
        last_refreshed_at: @last_refreshed_at,
        refresh_error: @refresh_error,
        refresh_interval: @refresh_interval
      }
    end
  end

  private

  def prioritize_locked(id)
    raise NotFound, 'Track is not in the playlist' unless @states.key?(id)
    return if id == @active || @analyzer.complete?(id)

    @queue.delete(id)
    @queue.unshift(id)
    @states[id] = { state: 'queued', error: nil }
    @changed.broadcast
  end

  def work
    loop do
      id = @mutex.synchronize do
        @changed.wait(@mutex) while @running && @queue.empty?
        return unless @running

        @active = @queue.shift
        @active_stage = 'analyzing'
        @states[@active] = { state: @active_stage, error: nil }
        @active
      end

      begin
        @analyzer.process(id) do |stage|
          @mutex.synchronize do
            @active_stage = stage
            @states[id] = { state: stage, error: nil } if @states.key?(id)
            @changed.broadcast
          end
        end
        @mutex.synchronize { @states[id] = { state: 'analyzed', error: nil } if @states.key?(id) }
      rescue StandardError => error
        @mutex.synchronize { @states[id] = { state: 'failed', error: error.message } if @states.key?(id) }
        warn "Analysis failed for #{id}: #{error.message}"
      ensure
        @mutex.synchronize do
          @analyzer.delete(id) unless @states.key?(id)
          @active = nil
          @changed.broadcast
        end
      end
    end
  end

  def poll
    loop do
      deadline = monotonic_time + @refresh_interval
      @mutex.synchronize do
        while @running && (remaining = deadline - monotonic_time).positive?
          @changed.wait(@mutex, remaining)
        end
        return unless @running
      end
      refresh
    end
  end

  def monotonic_time
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
