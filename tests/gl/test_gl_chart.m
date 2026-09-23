function test_gl_chart()
% TEST_GL_CHART  A line chart renders through NanoVG: the plot is not flat
%   and the series colour reaches the screen.

    if ~plv_gl_available(); plv_gl_skip('test_gl_chart'); return; end

    win = ptb_test_window();
    panelW = 200; panelH = 120;
    dst = [20 20 20 + panelW 20 + panelH];

    ui = PsychLVGLOpen(win, panelW, panelH, dst);
    closer = onCleanup(@() PsychLVGLClose(ui)); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    ch = PsychLVGL('ChartCreate', scr);
    PsychLVGL('ObjSetSize', ch, panelW, panelH);
    PsychLVGL('ObjCenter', ch);
    PsychLVGL('ChartSetType', ch, 'LV_CHART_TYPE_LINE');
    PsychLVGL('ChartSetPointCount', ch, 24);
    PsychLVGL('ChartSetAxisRange', ch, 'LV_CHART_AXIS_PRIMARY_Y', 0, 100);
    ser = PsychLVGL('ChartAddSeries', ch, [255 0 0], 'LV_CHART_AXIS_PRIMARY_Y');
    PsychLVGL('ChartSetValues', ch, ser, 50 + 45 * sin(linspace(0, 2 * pi, 24)));

    ui = PsychLVGLFrame(ui);
    img = double(Screen('GetImage', win, dst, 'drawBuffer'));
    Screen('Flip', win);

    plv_assert('the chart is not one flat colour', std(img(:)) > 10);
    red = img(:, :, 1) > 180 & img(:, :, 2) < 100 & img(:, :, 3) < 100;
    plv_assert('the red series line reaches the screen', sum(red(:)) > 20);

    % the per-frame setter path: one value per frame
    for k = 1:5
        PsychLVGL('ChartSetNextValue', ch, ser, 10 * k);
        ui = PsychLVGLFrame(ui);
        Screen('Flip', win);
    end
    plv_eq('streaming values left Psychtoolbox in 2D mode', plv_gl_drawmode(), 0);

    % GL_TIMESTAMP needs OpenGL 3.3 or GL_ARB_timer_query; a macOS 2.1
    % context has neither and reports 0.
    v = PsychLVGL('Version');
    ver = sscanf(v.glVersion, '%d.%d');
    s = PsychLVGL('Stats');
    if numel(ver) == 2 && (ver(1) > 3 || (ver(1) == 3 && ver(2) >= 3))
        plv_assert('Stats reports the GPU time of lv_timer_handler', s.gpuMaxNs > 0);
    end

    PsychLVGL('ObjDelete', ch);
    plv_assert('the series handle dies with its chart', ~PsychLVGL('IsValid', ser));
    PsychLVGLFrame(ui);
    Screen('Flip', win);
end
