require_relative 'test_helper'

class TrackAnalysisTest < AnalysisTest
  def test_failed_commands_do_not_publish_partial_files_and_can_be_retried
    @analyzer.define_singleton_method(:run) do |*command|
      File.write(command.last, 'partial conversion')
      raise 'conversion failed'
    end
    assert_raises(RuntimeError) { @analyzer.process(A) { |_| } }
    refute File.exist?(@analyzer.paths(A)[:audio])
    assert_empty Dir.glob(File.join(@root, 'audio', '*.tmp.wav'))
    @analyzer.singleton_class.remove_method(:run)
    @analyzer.process(A) { |_| }
    assert @analyzer.complete?(A)
  end

  def test_native_wav_is_copied_into_persistent_cache
    wav = File.join(@root, 'native.WAV')
    File.write(wav, 'native wav')
    library = FakeLibrary.new([A], wav)
    analyzer = FakeAnalysis.new(root: @root, library: library)
    analyzer.process(A) { |_| }
    assert_equal 'native wav', File.read(analyzer.paths(A)[:audio])
    refute_includes analyzer.commands.map(&:first), 'ffmpeg'
  end

  def test_missing_external_tool_is_reported_as_failure
    analyzer = TrackAnalysis.new(root: @root, library: @library)
    assert_raises(Errno::ENOENT) { analyzer.send(:run, '/nonexistent/audio-tool') }
  end

  def test_unsuccessful_external_tool_exit_includes_its_error_message
    analyzer = TrackAnalysis.new(root: @root, library: @library)
    error = assert_raises(RuntimeError) do
      analyzer.send(:run, RbConfig.ruby, '-e', "warn 'bad audio'; exit 1")
    end
    assert_includes error.message, 'bad audio'
  end

  def test_beat_grid_fitting_preserves_bpm_and_phase
    analyzer = TrackAnalysis.new(root: @root, library: @library)
    grid = analyzer.fit_beat_grid(Array.new(80) { |index| 0.12 + index * 0.5 }, 120)
    assert_in_delta 120, grid[:bpm], 0.01
    assert_in_delta 0.12, grid[:phase], 0.001
    assert_in_delta 1, grid[:confidence], 0.001
  end
end
