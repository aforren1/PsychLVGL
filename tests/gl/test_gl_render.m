function test_gl_render()
% TEST_GL_RENDER  A known background and one label read back within tolerance.
%   NanoVG antialiasing differs between GPUs, so the test compares region
%   means rather than pixels.

    if ~plv_gl_available(); plv_gl_skip('test_gl_render'); return; end

    win = ptb_test_window();
    panelW = 200; panelH = 120;
    dst = [20 20 20 + panelW 20 + panelH];

    Screen('BeginOpenGL', win);
    glTex = PsychLVGL('Init', panelW, panelH);
    Screen('EndOpenGL', win);

    global GL %#ok<GVMIS>
    tex = Screen('SetOpenGLTexture', win, [], glTex, GL.TEXTURE_2D, panelW, panelH);

    scr = PsychLVGL('ScreenActive');
    PsychLVGL('ObjSetStyleBgColor', scr, [0 0 255]);
    PsychLVGL('ObjSetStyleBgOpa', scr, 255);
    lbl = PsychLVGL('LabelCreate', scr);
    PsychLVGL('LabelSetText', lbl, 'psychlvgl');
    PsychLVGL('ObjAlign', lbl, 'LV_ALIGN_CENTER', 0, 0);

    Screen('BeginOpenGL', win);
    dirty = PsychLVGL('Update', GetSecs(), [0 0 0], 0, zeros(0, 2));
    Screen('EndOpenGL', win);
    plv_assert('the first Update renders', dirty == 1);

    Screen('DrawTexture', win, tex, [], dst);
    img = double(Screen('GetImage', win, dst, 'drawBuffer'));
    Screen('Flip', win);

    m = squeeze(mean(mean(img, 1), 2));
    plv_assert('the panel is mostly blue', m(3) > m(1) + 40 && m(3) > m(2) + 40);

    % Orientation: a white band along the top of the panel has to land at the
    % top on screen, which is what lets PsychLVGLFrame draw with no source
    % rectangle.
    band = PsychLVGL('ObjCreate', scr);
    PsychLVGL('ObjSetPos', band, 0, 0);
    PsychLVGL('ObjSetSize', band, panelW, 24);
    PsychLVGL('ObjSetStyleBgColor', band, [255 255 255]);
    PsychLVGL('ObjSetStyleBgOpa', band, 255);
    PsychLVGL('ObjSetStyleBorderWidth', band, 0);
    Screen('BeginOpenGL', win);
    PsychLVGL('Update', GetSecs(), [0 0 0], 0, zeros(0, 2));
    Screen('EndOpenGL', win);
    Screen('DrawTexture', win, tex, [], dst);
    img = double(Screen('GetImage', win, dst, 'drawBuffer'));
    Screen('Flip', win);
    topMean = mean(mean(mean(img(1:16, :, :))));
    botMean = mean(mean(mean(img(end-15:end, :, :))));
    plv_assert('the panel is not flipped vertically', topMean > botMean + 40);

    Screen('BeginOpenGL', win);
    PsychLVGL('Shutdown');
    Screen('EndOpenGL', win);
end
