require 'minitest/autorun'
require 'minitest/mock'
require 'tmpdir'
require 'timeout'
require_relative '../library'
require_relative '../analysis_queue'

class FakeLibrary
  attr_accessor :tracks, :refresh_error, :source
  attr_reader :lookups

  def initialize(ids, source)
    @tracks = ids.map { |id| PlaylistTrack.new(id, nil, "Track #{id}") }
    @source = source
    @lookups = []
  end

  def get_playlist_tracks(_playlist_id)
    raise @refresh_error if @refresh_error

    @tracks.dup
  end

  def get_track_location_and_duration(id)
    @lookups << id
    [@source, '120']
  end
end

# Exercise the real cache/pipeline code with deterministic substitutes for the
# external audio tools. A held track lets tests control refresh/request races.
class FakeAnalysis < TrackAnalysis
  attr_reader :started, :calls, :commands
  attr_accessor :failure

  def initialize(**args)
    super
    @started = Queue.new
    @calls = []
    @commands = []
    @holds = {}
  end

  def hold(id)
    @holds[id] = Queue.new
  end

  def release_all
    @holds.each_value { |queue| queue << true }
  end

  def process(id, &block)
    @calls << id
    @started << id
    @holds[id]&.pop
    raise 'tool failed' if @failure == id

    super
  end

  private

  def run(*command)
    @commands << command
    case command.first
    when 'ffmpeg'
      File.write(command.last, 'decoded audio')
    when 'audiowaveform'
      File.write(command[command.index('-o') + 1], 'waveform data')
    end
    '' # An audio file with no detected beat is still successfully analyzed.
  end
end

class AnalysisTest < Minitest::Test
  A = 'AAAAAAAAAAAAAAAA'
  B = 'BBBBBBBBBBBBBBBB'
  C = 'CCCCCCCCCCCCCCCC'

  def setup
    @root = Dir.mktmpdir('track-analysis-test')
    @source = File.join(@root, 'source with spaces.m4a')
    File.write(@source, 'source audio')
    @library = FakeLibrary.new([A, B, C], @source)
    @analyzer = FakeAnalysis.new(root: @root, library: @library)
    @queue = build_queue
  end

  def teardown
    @analyzer.release_all
    @queue.stop
    FileUtils.remove_entry(@root)
  end

  def build_queue(refresh_interval: 60)
    AnalysisQueue.new(playlist_id: 'playlist', root: @root, library: @library,
                      analyzer: @analyzer, refresh_interval: refresh_interval)
  end

  def eventually
    Timeout.timeout(5) do
      sleep 0.005 until yield
    end
  end

  def next_started
    Timeout.timeout(5) { @analyzer.started.pop }
  end

  def cache(id, complete: true)
    files = @analyzer.paths(id)
    File.write(files[:audio], 'cached audio')
    File.write(files[:waveform], 'cached waveform')
    File.write(files[:beats], JSON.generate(bpm: 120, phase: 0, confidence: 1)) if complete
    files
  end
end
