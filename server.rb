require 'sinatra/base'
require 'sinatra/json'
require 'htmlentities'
require 'fileutils'
require_relative 'library'

PLAYLIST_ID = '4D860944EB057E94'
ARTWORK_DIR = (File.dirname(__FILE__) + '/artwork/').gsub(/^\//, '').gsub('/', ':')
WAVEFORM_WIDTH = 1140
WAVEFORM_SMALL_HEIGHT = 35
WAVEFORM_BIG_HEIGHT = 90
WAVEFORM_BIG_WIDTH_DURATION = 30 # seconds
WAVEFORM = Struct.new(:width, :small_height, :big_height, :big_width_duration).new(WAVEFORM_WIDTH, WAVEFORM_SMALL_HEIGHT, WAVEFORM_BIG_HEIGHT, WAVEFORM_BIG_WIDTH_DURATION)
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

  get '/' do
    erb :index, locals: { playlist_tracks: Library.get_playlist_tracks(PLAYLIST_ID) }
  end

  get '/audio/:id' do
    file, _ = Library.get_track_location_and_duration(params[:id])
    send_file file, type: file.split('.').last
  end

  get '/waveform/:id.big.2x.png' do
    send_file generate_big_waveform(params[:id], 2)
  end

  get '/waveform/:id.big.1x.png' do
    send_file generate_big_waveform(params[:id], 1)
  end

  get '/waveform/:id.small.2x.png' do
    send_file generate_small_waveform(params[:id], 2)
  end

  get '/waveform/:id.small.1x.png' do
    send_file generate_small_waveform(params[:id], 1)
  end

  get '/track/:id' do
    id = params[:id]
    Thread.new do
      converted_file, in_progress = get_converted_info(id)
      in_file, _ = Library.get_track_location_and_duration(id)
      if is_m4a(in_file) && !File.exists?(converted_file)
        FileUtils.touch(in_progress)
        puts "======== Starting Conversion #{File.basename(in_file)} -> #{converted_file} ========"
        puts "ffmpeg -i #{in_file.shellescape} -acodec libmp3lame -ab 128k #{converted_file.shellescape} &>/dev/null"
        `ffmpeg -i #{in_file.shellescape} -acodec libmp3lame -ab 128k #{converted_file.shellescape} &>/dev/null`
        puts "======== Conversion Done #{File.basename(in_file)} -> #{converted_file} ========"
        FileUtils.rm(in_progress)
      end
    end

    erb :track, locals: { track_id: params[:id], track: Library.get_track(params[:id], ARTWORK_DIR), waveform: WAVEFORM }
  end

  post '/track/:id' do
    track = Track.new(params[:name], params[:artist], params[:album], params[:album_artist], params[:genre], params[:year],
                      params[:track], params[:track_count], params[:disc], params[:disc_count], params[:start], params[:finish])
    Library.set_track_info(params[:id], track)
    Library.delete_track_artwork(params[:id]) if params[:clear_artworks] && params[:clear_artworks] == 'yes'

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

    while !order.empty?
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
                          params[:genre], params[:year], track+1, track_count, disc+1, disc_count)
        Library.set_track_info(track_id, track, false)
      end
    end

    redirect to('/')
  end

  private

  def is_m4a(file)
    file[-4..-1] == '.m4a'
  end

  def get_converted_info(id)
    converted_file = "audio/#{id}.mp3"
    in_progress = "audio/#{id}.mp3.wip"
    [converted_file, in_progress]
  end

  def generate_big_waveform(track_id, scale)
    generate_waveform(track_id, 'big', scale, WAVEFORM_WIDTH, WAVEFORM_BIG_HEIGHT, true)
  end

  def generate_small_waveform(track_id, scale)
    generate_waveform(track_id, 'small', scale, WAVEFORM_WIDTH, WAVEFORM_SMALL_HEIGHT, false)
  end

  def generate_waveform(track_id, size, scale, base_width, height, scale_width)
    file, duration = Library.get_track_location_and_duration(params[:id])
    destination = "waveforms/#{params[:id]}.#{size}.#{scale}.png" # waveforms/ABCD.big.1x.png
    converted_file, in_progress = get_converted_info(params[:id])

    if scale_width
      base_width = (base_width * duration.to_f / WAVEFORM_BIG_WIDTH_DURATION).ceil
    end

    if is_m4a(file)
      file = converted_file

      log = true
      while File.exists?(in_progress) || !File.exists?(converted_file)
        puts "Waiting on conversion for #{destination}..." if log
        log = false
        sleep 0.5
      end
    end

    if !File.exists?(destination)
      puts "audiowaveform -i #{file.shellescape} -o #{destination.shellescape} -s 0 -e #{duration} -w #{base_width*scale} -h #{height*scale} --background-color FFFFFF --no-axis-labels &>/dev/null"
      `audiowaveform -i #{file.shellescape} -o #{destination.shellescape} -s 0 -e #{duration} -w #{base_width*scale} -h #{height*scale} --background-color FFFFFF --no-axis-labels &>/dev/null`
    end
    send_file destination
  end
end
