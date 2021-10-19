require 'tempfile'

PLAYLIST_TRACKS = <<-SCRIPT
  set output to ""

  tell application "Music"
    repeat with thisPlaylist in user playlists
      try
        if persistent ID of thisPlaylist is not equal to "%s" then
          error 0
        end if
        repeat with thisTrack in file tracks of thisPlaylist
          set output to output & persistent ID of thisTrack & "::"
          set output to output & artist of thisTrack & " - "
          set output to output & name of thisTrack & "\n"
        end repeat
      end try
    end repeat
  end tell

  output
SCRIPT

TRACK_INFO = <<-SCRIPT
  set output to ""

  tell application "Music"
    set theseTracks to tracks in playlist 1 whose persistent ID is "%s"
    set thisTrack to item 1 of theseTracks

    set output to output & name of thisTrack & "\n"
    set output to output & artist of thisTrack & "\n"
    set output to output & album of thisTrack & "\n"
    set output to output & album artist of thisTrack & "\n"
    set output to output & genre of thisTrack & "\n"
    set output to output & year of thisTrack & "\n"
    set output to output & track number of thisTrack & "\n"
    set output to output & track count of thisTrack & "\n"
    set output to output & disc number of thisTrack & "\n"
    set output to output & disc count of thisTrack & "\n"
    set output to output & start of thisTrack & "\n"
    set output to output & finish of thisTrack & "\n"
    set output to output & duration of thisTrack & "\n"
  end tell

  output
SCRIPT

TRACK_ARTWORK = <<-SCRIPT
  set output to ""

  tell application "Music"
    set theseTracks to tracks in playlist 1 whose persistent ID is "%s"
    set thisTrack to item 1 of theseTracks

    set i to -1
    repeat with thisArtwork in artworks of thisTrack
      set i to i + 1

      set srcBytes to raw data of thisArtwork
      if format of thisArtwork is JPEG picture then
        set ext to ".jpg"
      else
        set ext to ".png"
      end if

      set fileName to ("%s" & (persistent ID of thisTrack) & "_" & (i as string) & ext)
      set output to output & (persistent ID of thisTrack) & "_" & (i as string) & ext & "\n"
      set outFile to open for access file fileName with write permission
      set eof outFile to 0
      write srcBytes to outFile
      close access outFile
    end repeat
  end tell

  output
SCRIPT

SET_TRACK_INFO = <<-SCRIPT
  set output to ""

  tell application "Music"
    set theseTracks to tracks in playlist 1 whose persistent ID is "%s"
    set thisTrack to item 1 of theseTracks
    set updateTimes to %s

    set name of thisTrack to "%s"
    set artist of thisTrack to "%s"
    set album of thisTrack to "%s"
    set album artist of thisTrack to "%s"
    set genre of thisTrack to "%s"
    set year of thisTrack to "%s"
    set track number of thisTrack to %s
    set track count of thisTrack to %s
    set disc number of thisTrack to %s
    set disc count of thisTrack to %s
    if updateTimes then
      set start of thisTrack to "%s"
      set finish of thisTrack to "%s"
    end if
    set comment of thisTrack to ""
    set composer of thisTrack to ""
    set compilation of thisTrack to false
    set grouping of thisTrack to ""
  end tell

  output
SCRIPT

DELETE_TRACK_ARTWORK = <<-SCRIPT
  set output to ""

  tell application "Music"
    set theseTracks to tracks in playlist 1 whose persistent ID is "%s"
    set thisTrack to item 1 of theseTracks

    repeat while count of artworks of thisTrack > 0
      delete artwork 1 of thisTrack
    end repeat
  end tell

  output
SCRIPT

TRACK_LOCATION_AND_DURATION = <<-SCRIPT
  set output to ""

  tell application "Music"
    set theseTracks to tracks in playlist 1 whose persistent ID is "%s"
    set thisTrack to item 1 of theseTracks

    set output to output & location of thisTrack as text & "\n"
    set output to output & duration of thisTrack as text
  end tell

  output
SCRIPT

MOVE_TRACK = <<-SCRIPT
  tell application "Music"
    set fromPlaylist to item 1 of (every user playlist whose persistent ID is "%s")
    set toPlaylist to item 1 of (every user playlist whose persistent ID is "%s")
    set fromPlaylistTrack to item 1 of (every track of fromPlaylist whose persistent ID is "%s")

    duplicate fromPlaylistTrack to toPlaylist
    delete fromPlaylistTrack
  end tell
SCRIPT

PlaylistTrack = Struct.new(:id, :desc)
Track = Struct.new(:name, :artist, :album, :album_artist, :genre, :year, :track, :track_count, :disc, :disc_count, :start, :finish, :duration, :artworks)
TRACK_FIELDS_COUNT = Track.new.length

module Library
  module_function

  def get_playlist_tracks(playlist_id)
    lines = execute_applescript(PLAYLIST_TRACKS, playlist_id).split("\n").sort
    lines.map { |line| PlaylistTrack.new(*line.split('::', 2)) }
  end

  def get_track(track_id, artwork_out_dir)
    lines = execute_applescript(TRACK_INFO, track_id).strip
    lines += "\n" + execute_applescript(TRACK_ARTWORK, [track_id, artwork_out_dir]).strip unless artwork_out_dir.nil?
    lines = lines.split("\n", TRACK_FIELDS_COUNT)

    track = Track.new(*lines)
    track.artworks = track.artworks.nil? ? [] : track.artworks.split("\n")
    track
  end

  def get_track_location_and_duration(track_id)
    location, duration = execute_applescript(TRACK_LOCATION_AND_DURATION, track_id).strip.split("\n")
    location = location.gsub(/^[^:]+/, '').gsub(':', '/')
    [location, duration]
  end

  def set_track_info(track_id, track, update_times = true)
    puts execute_applescript(SET_TRACK_INFO, [track_id, update_times.to_s, track.name, track.artist, track.album, track.album_artist,
      track.genre, track.year, track.track, track.track_count, track.disc, track.disc_count, track.start, track.finish])
  end

  def delete_track_artwork(track_id)
    execute_applescript(DELETE_TRACK_ARTWORK, track_id)
  end

  def move_track(from_playlist_id, to_playlist_id, track_id)
    execute_applescript(MOVE_TRACK, [from_playlist_id, to_playlist_id, track_id])
  end


  def execute_applescript(template, args = [])
    args = [args] unless args.is_a?(Array)
    args = args.map { |arg| arg.to_s.gsub('"', '\"').gsub('\\', '\\\\\\\\') }
    text = template % args

    file = Tempfile.new('applescript')
    file.write(text)
    file.close

    output = `osascript #{file.path}`
    file.unlink

    output
  end
end
