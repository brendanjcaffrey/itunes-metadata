require 'sinatra/base'
require 'sinatra/json'
require 'htmlentities'
require_relative 'library'

PLAYLIST_ID = '4D860944EB057E94'
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
    dir = (File.dirname(__FILE__) + '/artwork/').gsub(/^\//, '').gsub('/', ':')
    erb :track, locals: { track_id: params[:id], track: Library.get_track(params[:id], dir), waveform: WAVEFORM }
  end

  post '/track/:id' do
    track = Track.new(params[:name], params[:artist], params[:album], params[:album_artist], params[:genre], params[:year],
                      params[:track], params[:track_count], params[:disc], params[:disc_count], params[:start], params[:finish])
    Library.set_track_info(params[:id], track)

    Library.delete_track_artwork(params[:id]) if params[:clear_artworks] && params[:clear_artworks] == 'yes'
    redirect to('/')
  end

  private

  def generate_big_waveform(track_id, scale)
    generate_waveform(track_id, 'big', scale, WAVEFORM_WIDTH, WAVEFORM_BIG_HEIGHT, true)
  end

  def generate_small_waveform(track_id, scale)
    generate_waveform(track_id, 'small', scale, WAVEFORM_WIDTH, WAVEFORM_SMALL_HEIGHT, false)
  end

  def generate_waveform(track_id, size, scale, base_width, height, scale_width)
    file, duration = Library.get_track_location_and_duration(params[:id])
    destination = "waveforms/#{params[:id]}.#{size}.#{scale}.png" # waveforms/ABCD.big.1x.png

    if scale_width
      base_width = (base_width * duration.to_f / WAVEFORM_BIG_WIDTH_DURATION).ceil
    end

    if !File.exists?(destination)
      puts "audiowaveform -i \"#{file}\" -o \"#{destination}\" -s 0 -e #{duration} -w #{base_width*scale} -h #{height*scale} --background-color FFFFFF --no-axis-labels"
      puts `audiowaveform -i "#{file}" -o "#{destination}" -s 0 -e #{duration} -w #{base_width*scale} -h #{height*scale} --background-color FFFFFF --no-axis-labels`
    end
    send_file destination
  end
end
