function test_gl_click()
% TEST_GL_CLICK  A press and release through PsychLVGLGL produces CLICKED and
%   moves the widget through the pressed state.
%
%   The pointer is synthetic, so the frames go through PsychLVGLGL rather than
%   PsychLVGLFrame, which reads the real mouse.
%
%   SPEC 11.2 also asks for the pressed state to be visible in a read back
%   image. On this machine Screen('GetImage') of a sub-region of a windowed
%   window returned identical pixels for two different frames, so the widget
%   state is checked here and test_gl_render carries the pixel checks.

    if ~plv_gl_available(); plv_gl_skip('test_gl_click'); return; end

    win = ptb_test_window();
    panelW = 200; panelH = 120;
    dst = [20 20 20 + panelW 20 + panelH];

    ui = PsychLVGLOpen(win, panelW, panelH, dst);
    closer = onCleanup(@() PsychLVGLClose(ui)); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    btn = PsychLVGL('ButtonCreate', scr);
    PsychLVGL('ObjSetPos', btn, 20, 20);
    PsychLVGL('ObjSetSize', btn, 120, 50);

    t = GetSecs();
    PsychLVGLGL(ui, 'Update', t, [0 0 0], 0, zeros(0, 2));
    PsychLVGL('Poll');
    Screen('DrawTexture', win, ui.tex, [], dst);
    Screen('Flip', win);

    plv_assert('the button starts released', ...
               ~PsychLVGL('ObjHasState', btn, 'LV_STATE_PRESSED'));

    dirty = PsychLVGLGL(ui, 'Update', t + 0.1, [80 45 1], 0, zeros(0, 2));
    Screen('DrawTexture', win, ui.tex, [], dst);
    Screen('Flip', win);

    plv_assert('the press reaches the button', ...
               PsychLVGL('ObjHasState', btn, 'LV_STATE_PRESSED'));
    plv_assert('the press causes a redraw', dirty == 1);
    plv_eq('the wrapper left 2D mode', plv_gl_drawmode(), 0);

    PsychLVGLGL(ui, 'Update', t + 0.2, [80 45 0], 0, zeros(0, 2));

    plv_assert('the release clears the pressed state', ...
               ~PsychLVGL('ObjHasState', btn, 'LV_STATE_PRESSED'));

    E = PsychLVGL('Poll');
    clicked  = PsychLVGL('Enum', 'LV_EVENT_CLICKED');
    pressed  = PsychLVGL('Enum', 'LV_EVENT_PRESSED');
    released = PsychLVGL('Enum', 'LV_EVENT_RELEASED');
    plv_assert('PRESSED reaches Poll', any(E(:, 2) == pressed & E(:, 1) == btn));
    plv_assert('RELEASED reaches Poll', any(E(:, 2) == released & E(:, 1) == btn));
    plv_assert('CLICKED reaches Poll', any(E(:, 2) == clicked & E(:, 1) == btn));
end
