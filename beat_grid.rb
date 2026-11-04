module BeatGrid
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

end
