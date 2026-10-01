require 'sinatra/base'
require 'htmlentities'
require 'fileutils'
require 'shellwords'
require 'json'
require_relative 'library'

PLAYLIST_ID = '4D860944EB057E94'
TO_PLAYLIST_ID = '47C05645C4AAAE4F'
ARTWORK_DIR = (File.dirname(__FILE__) + '/artwork/').gsub(%r{^/}, '').gsub('/', ':')
MIME_TYPES = {
  'mp3' => 'audio/mpeg',
  'mp4' => 'audio/mp4',
  'm4a' => 'audio/mp4',
  'aif' => 'audio/aif',
  'aiff' => 'audio/aif',
  'wav' => 'audio/wav'
}

class Server < Sinatra::Base
  configure do
    MIME_TYPES.each do |key, value|
      mime_type key.to_sym, value
    end
  end

  set :environment, :development
  set :views, '.'
  set :public_folder, File.dirname(__FILE__) + '/artwork'
  set :port, 4568
  set :server_settings, {
    ShutdownTimeout: 1
  }
  enable :sessions

  before do
    headers 'Access-Control-Allow-Origin' => '*'
  end

  get '/' do
    reverse = !!session[:reverse]
    tracks = Library.get_playlist_tracks(PLAYLIST_ID)
    tracks.reverse! if reverse
    erb :index, locals: { playlist_tracks: tracks, last_viewed: session[:last_viewed], reverse: reverse }
  end

  get '/reverse' do
    session[:reverse] = !session[:reverse]
    redirect to('/')
  end

  get '/audio/:id' do
    file, = Library.get_track_location_and_duration(params[:id])
    converted_file, in_progress = get_converted_info(params[:id])

    unless is_wav(file)
      file = converted_file

      log = true
      while File.exist?(in_progress) || !File.exist?(converted_file)
        puts "Waiting on conversion for #{converted_file}..." if log
        log = false
        sleep 0.5
      end
    end

    send_file file, type: file.split('.').last
  end

  get '/waveform/:id.dat' do
    send_file generate_waveform_dat(params[:id])
  end

  get '/beats/:id.json' do
    content_type :json
    send_file generate_beats_json(params[:id])
  end

  get '/track/:id' do
    id = params[:id]
    session[:last_viewed] = id

    converted_file, in_progress = get_converted_info(id)
    in_file, = Library.get_track_location_and_duration(id)
    if !is_wav(in_file) && !File.exist?(converted_file)
      FileUtils.touch(in_progress)
      puts "======== Starting Conversion #{File.basename(in_file)} -> #{converted_file} ========"
      puts "ffmpeg -i #{in_file.shellescape} #{converted_file.shellescape} &>/dev/null"
      pid = Process.spawn("ffmpeg -i #{in_file.shellescape} #{converted_file.shellescape} &>/dev/null; rm #{in_progress.shellescape}")
      Process.detach(pid)
    end

    erb :track, locals: { track_id: params[:id], track: Library.get_track(params[:id], ARTWORK_DIR) }
  end

  post '/track/:id' do
    track = Track.new(params[:name], params[:artist], params[:album], params[:album_artist], params[:genre], params[:year],
                      params[:track], params[:track_count], params[:disc], params[:disc_count], params[:start], params[:finish],
                      params[:bpm])
    Library.set_track_info(params[:id], track)
    Library.delete_track_artwork(params[:id]) if params[:clear_artworks] && params[:clear_artworks] == 'yes'
    Library.move_track(PLAYLIST_ID, TO_PLAYLIST_ID, params[:id]) if params[:move] && params[:move] == 'yes'

    redirect to('/')
  end

  get '/album' do
    track_ids = Library.get_playlist_tracks(PLAYLIST_ID).map { |playlist_track| playlist_track.id }
    tracks = track_ids.zip(track_ids.map { |track_id| Library.get_track(track_id, nil) })
    tracks = tracks.sort do |track1, track2|
      if track1[1].disc == track2[1].disc
        track1[1].track.to_i <=> track2[1].track.to_i
      else
        track1[1].disc.to_i <=> track2[1].disc.to_i
      end
    end
    erb :album, locals: { tracks: tracks }
  end

  post '/album' do
    order = params[:order].split(',')
    order = order[0..-2] if order[-1] == 'DISC'
    discs = [[]]

    until order.empty?
      id = order.shift
      if id == 'DISC'
        discs << []
      else
        discs[-1] << id
      end
    end

    disc_count = discs.count
    discs.each_with_index do |tracks, disc|
      track_count = tracks.count
      tracks.each_with_index do |track_id, track|
        track = Track.new(params[:names][track_id], params[:artist], params[:album], params[:artist],
                          params[:genre], params[:year], track + 1, track_count, disc + 1, disc_count)
        Library.set_track_info(track_id, track, false)
      end
    end

    redirect to('/')
  end

  private

  def is_wav(file)
    file[-4..-1] == '.wav'
  end

  def get_converted_info(id)
    converted_file = "audio/#{id}.wav"
    in_progress = "audio/#{id}.wav.wip"
    [converted_file, in_progress]
  end

  # Waits for the wav conversion kicked off by GET /track/:id, then returns the
  # path to the decoded file that analysis tools should read.
  def wait_for_wav(track_id, waiting_on)
    file, = Library.get_track_location_and_duration(track_id)
    return file if is_wav(file)

    converted_file, in_progress = get_converted_info(track_id)
    log = true
    while File.exist?(in_progress) || !File.exist?(converted_file)
      puts "Waiting on conversion for #{waiting_on}..." if log
      log = false
      sleep 0.5
    end
    converted_file
  end

  def generate_beats_json(track_id)
    destination = "beats/#{track_id}.json"
    return destination if File.exist?(destination)

    file = wait_for_wav(track_id, destination)
    puts "aubiotrack -i #{file.shellescape}"
    beats = `aubiotrack -i #{file.shellescape} 2>/dev/null`.split("\n").map(&:to_f).select { |time| time > 0 }
    seed_bpm = `aubio tempo -i #{file.shellescape} 2>/dev/null`[/[\d.]+/]&.to_f

    FileUtils.mkdir_p('beats')
    File.write(destination, JSON.generate(fit_beat_grid(beats, seed_bpm)))
    destination
  end

  TWO_PI = 2 * Math::PI

  # How tightly the detected beats bunch around a grid of this period, as a
  # strength from 0 (scattered) to 1 (every beat exactly on a line), plus the
  # angle that says where the grid lines fall.
  def beat_coherence(beats, period)
    sin = cos = 0.0
    beats.each do |time|
      angle = TWO_PI * time / period
      sin += Math.sin(angle)
      cos += Math.cos(angle)
    end
    [Math.hypot(sin, cos) / beats.length, Math.atan2(sin, cos)]
  end

  # Numbers the beats that already sit close to the grid and refits the line
  # through them, so stray detections in noisy passages stop pulling on it.
  def polish_beat_grid(beats, period, phase)
    2.times do
      on_grid = beats.map { |time| [((time - phase) / period).round, time] }
                     .select { |number, time| ((time - (phase + number * period)) / period).abs < 0.15 }
      return [period, phase] if on_grid.length < 8

      mean_number = on_grid.sum { |number, _| number }.to_f / on_grid.length
      mean_time = on_grid.sum { |_, time| time } / on_grid.length
      covariance = on_grid.sum { |number, time| (number - mean_number) * (time - mean_time) }
      variance = on_grid.sum { |number, _| (number - mean_number)**2 }
      return [period, phase] if variance.zero?

      period = covariance / variance
      phase = mean_time - period * mean_number
    end
    [period, phase]
  end

  # Fits a constant tempo grid (time = phase + beat_number * period) to aubio's
  # beat times. aubio drops beats in intros and breakdowns, so counting off a
  # fitted grid keeps "forward 16 beats" honest where indexing into the raw
  # list of detected beats would quietly come up short.
  def fit_beat_grid(beats, seed_bpm)
    return { bpm: nil, phase: 0.0, confidence: 0.0 } if beats.length < 16 || seed_bpm.nil? || seed_bpm <= 0

    # aubio's global tempo lands within a few percent but not on the nose, and
    # even a 0.2% error walks the grid a whole beat off by the end of a track.
    # Scan that neighbourhood finely and keep the period whose grid the
    # detected beats cluster on most tightly.
    seed_period = 60.0 / seed_bpm
    best_period = seed_period
    best_strength = -1.0
    best_angle = 0.0
    steps = 4000
    (-steps..steps).each do |step|
      period = seed_period * (1.0 + 0.05 * step / steps)
      strength, angle = beat_coherence(beats, period)
      next unless strength > best_strength

      best_period = period
      best_strength = strength
      best_angle = angle
    end

    period, phase = polish_beat_grid(beats, best_period, best_angle / TWO_PI * best_period)

    # aubio locks onto whichever pulse it is most confident in, which is often
    # half or double the musical tempo, so fold the result into the range most
    # of this library sits in. Both foldings leave the grid on detected beats.
    bpm = 60.0 / period
    bpm *= 2 while bpm < 70
    bpm /= 2 while bpm >= 180

    period = 60.0 / bpm
    phase -= period * (phase / period).floor
    { bpm: bpm.round(2), phase: phase.round(4), confidence: best_strength.round(3) }
  end

  def generate_waveform_dat(_track_id)
    file, duration = Library.get_track_location_and_duration(params[:id])
    destination = "waveforms/#{params[:id]}.dat"
    converted_file, in_progress = get_converted_info(params[:id])

    unless is_wav(file)
      file = converted_file

      log = true
      while File.exist?(in_progress) || !File.exist?(converted_file)
        puts "Waiting on conversion for #{destination}..." if log
        log = false
        sleep 0.5
      end
    end

    unless File.exist?(destination)
      puts "audiowaveform -i #{file.shellescape} -o #{destination.shellescape} -b 8 &>/dev/null"
      `audiowaveform -i #{file.shellescape} -o #{destination.shellescape} -b 8 &>/dev/null`
    end
    send_file destination
  end
end
