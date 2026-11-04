require 'sinatra/base'
require 'htmlentities'
require 'json'
require_relative 'library'
require_relative 'analysis_queue'

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

  set :analysis_queue, AnalysisQueue.new(
    playlist_id: PLAYLIST_ID,
    library: Library,
    refresh_interval: ENV.fetch('PLAYLIST_REFRESH_INTERVAL', '60')
  )

  def self.run!(*args, &block)
    settings.analysis_queue.start
    super
  ensure
    settings.analysis_queue.stop
  end

  before do
    headers 'Access-Control-Allow-Origin' => '*'
    settings.analysis_queue.start
  end

  get '/' do
    reverse = !!session[:reverse]
    tracks = settings.analysis_queue.playlist_tracks
    tracks.reverse! if reverse
    erb :index, locals: { playlist_tracks: tracks, last_viewed: session[:last_viewed], reverse: reverse }
  end

  get '/reverse' do
    session[:reverse] = !session[:reverse]
    redirect to('/')
  end

  get '/api/status' do
    content_type :json
    headers 'Cache-Control' => 'no-store'
    JSON.generate(settings.analysis_queue.status)
  end

  get '/audio/:id' do
    send_file analysis_file(:audio), type: :wav
  end

  get '/waveform/:id.dat' do
    send_file analysis_file(:waveform)
  end

  get '/beats/:id.json' do
    send_file analysis_file(:beats), type: :json
  end

  get '/track/:id' do
    id = params[:id].upcase
    settings.analysis_queue.prioritize(id)
    session[:last_viewed] = id

    erb :track, locals: { track_id: id, track: Library.get_track(id, ARTWORK_DIR) }
  end

  post '/track/:id' do
    id = params[:id].upcase
    track = Track.new(params[:name], params[:artist], params[:album], params[:album_artist], params[:genre], params[:year],
                      params[:track], params[:track_count], params[:disc], params[:disc_count], params[:start], params[:finish],
                      params[:bpm])
    Library.set_track_info(id, track)
    settings.analysis_queue.update_track(id, track)
    Library.delete_track_artwork(id) if params[:clear_artworks] && params[:clear_artworks] == 'yes'
    Library.move_track(PLAYLIST_ID, TO_PLAYLIST_ID, id) if params[:move] && params[:move] == 'yes'

    redirect to('/')
  end

  get '/album' do
    track_ids = settings.analysis_queue.playlist_tracks.map { |playlist_track| playlist_track.id }
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

  error AnalysisQueue::NotFound do
    content_type :json
    halt 404, JSON.generate(error: env['sinatra.error'].message)
  end

  error AnalysisQueue::Unavailable do
    content_type :json
    headers 'Retry-After' => '3'
    halt 503, JSON.generate(error: env['sinatra.error'].message)
  end

  private

  def analysis_file(artifact)
    settings.analysis_queue.wait_for(params[:id].upcase, artifact)
  end
end
