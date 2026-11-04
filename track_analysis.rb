require 'fileutils'
require 'json'
require 'open3'
require_relative 'beat_grid'

# Cache identity is Music's persistent ID, deliberately independent of source
# paths, modification times and tags. Only completed files get their final name.
class TrackAnalysis
  include BeatGrid

  def initialize(root:, library:)
    @root = root
    @library = library
    %w[audio waveforms beats artwork].each { |dir| FileUtils.mkdir_p(File.join(root, dir)) }
  end

  def paths(id)
    raise ArgumentError, 'Invalid persistent track ID' unless /\A[0-9A-F]{16}\z/.match?(id)

    {
      audio: File.join(@root, 'audio', "#{id}.wav"),
      waveform: File.join(@root, 'waveforms', "#{id}.dat"),
      beats: File.join(@root, 'beats', "#{id}.json")
    }
  end

  def artifacts(id)
    files = paths(id)
    beats = JSON.parse(File.read(files[:beats])) if File.size?(files[:beats])
    {
      audio: !!File.size?(files[:audio]),
      waveform: !!File.size?(files[:waveform]),
      beats: !!(beats.is_a?(Hash) && beats.key?('bpm') && beats.key?('phase') && beats.key?('confidence')),
      bpm: beats.is_a?(Hash) ? beats['bpm'] : nil
    }
  rescue JSON::ParserError
    { audio: !!File.size?(files[:audio]), waveform: !!File.size?(files[:waveform]), beats: false, bpm: nil }
  end

  def complete?(id)
    artifacts(id).values_at(:audio, :waveform, :beats).all?
  end

  def process(id)
    files = paths(id)
    unless artifacts(id)[:audio]
      yield 'converting'
      source, = @library.get_track_location_and_duration(id)
      atomic_output(files[:audio]) do |temporary|
        if File.extname(source).downcase == '.wav'
          FileUtils.cp(source, temporary)
        else
          run('ffmpeg', '-nostdin', '-y', '-formatprobesize', '2097152', '-i', source, '-vn', temporary)
        end
      end
    end

    unless artifacts(id)[:waveform]
      yield 'waveform'
      atomic_output(files[:waveform]) do |temporary|
        run('audiowaveform', '-i', files[:audio], '-o', temporary, '-b', '8')
      end
    end

    unless artifacts(id)[:beats]
      yield 'bpm'
      beats = run('aubiotrack', '-i', files[:audio]).lines.map(&:to_f).select(&:positive?)
      seed_bpm = run('aubio', 'tempo', '-i', files[:audio])[/[\d.]+/]&.to_f
      atomic_output(files[:beats]) do |temporary|
        File.write(temporary, JSON.generate(fit_beat_grid(beats, seed_bpm)))
      end
    end
  end

  # The queue keeps the active ID here until its worker finishes. That avoids
  # deleting input/output underneath a subprocess when a track is removed.
  def cleanup(keep_ids)
    %w[audio waveforms beats artwork].each do |dir|
      Dir.glob(File.join(@root, dir, '*')).each do |file|
        id = File.basename(file)[/\A([0-9A-F]{16})[._]/, 1]
        FileUtils.rm_f(file) if id && !keep_ids.include?(id)
      end
    end
  end

  def delete(id)
    %w[audio waveforms beats artwork].each do |dir|
      Dir.glob(File.join(@root, dir, "#{id}[._]*")).each { |file| FileUtils.rm_f(file) }
    end
  end

  private

  def run(*command)
    output, error, status = Open3.capture3(*command)
    raise "#{command.first} failed: #{error.strip[-1000, 1000] || error.strip}" unless status.success?

    output
  end

  def atomic_output(destination)
    extension = File.extname(destination)
    temporary = destination.delete_suffix(extension) + '.tmp' + extension
    yield temporary
    raise "No output generated for #{File.basename(destination)}" unless File.size?(temporary)

    File.rename(temporary, destination)
  ensure
    FileUtils.rm_f(temporary) if temporary
  end
end
