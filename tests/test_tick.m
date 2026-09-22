function test_tick()
% TEST_TICK  Synthetic times drive LVGL and non-monotonic times are counted.

    PsychLVGL('Init', 160, 120);
    c = onCleanup(@() PsychLVGL('Shutdown')); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    lbl = PsychLVGL('LabelCreate', scr);
    PsychLVGL('LabelSetText', lbl, 'tick');

    t0 = 1000;
    dirty = PsychLVGL('Update', t0, [0 0 0], 0, zeros(0, 2));
    plv_assert('the first Update renders', dirty == 1);

    dirty = PsychLVGL('Update', t0 + 0.016, [0 0 0], 0, zeros(0, 2));
    plv_assert('an idle Update does not render', dirty == 0);

    PsychLVGL('LabelSetText', lbl, 'changed');
    dirty = PsychLVGL('Update', t0 + 0.032, [0 0 0], 0, zeros(0, 2));
    plv_assert('a changed widget renders again', dirty == 1);

    s = PsychLVGL('Stats');
    plv_eq('Update is counted', s.updateCount, 3);
    plv_assert('Update is timed', s.updateSumNs > 0);
    plv_eq('no tick anomaly yet', s.tickAnomaly, 0);
    plv_assert('the flush callback ran', s.flushCount >= 2);

    % time that goes backwards must not freeze the tick
    PsychLVGL('Update', t0 - 5, [0 0 0], 0, zeros(0, 2));
    s = PsychLVGL('Stats');
    plv_eq('a backwards clock is counted', s.tickAnomaly, 1);

    PsychLVGL('Update', t0 + 1, [0 0 0], 0, zeros(0, 2));
    s = PsychLVGL('Stats');
    plv_eq('a forward clock is not counted', s.tickAnomaly, 1);

    PsychLVGL('StatsAddFrame', 0.016);
    s = PsychLVGL('Stats');
    plv_eq('StatsAddFrame counts a frame', s.frameCount, 1);
    plv_assert('StatsAddFrame records the time', s.frameLastNs > 1e6);
end
