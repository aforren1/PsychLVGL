function test_gl_style()
% TEST_GL_STYLE  A shared lv_style_t colours the object it is added to, and a
%   change to the style reaches the screen on the next frame.

    if ~plv_gl_available(); plv_gl_skip('test_gl_style'); return; end

    win = ptb_test_window();
    panelW = 160; panelH = 100;
    dst = [20 20 20 + panelW 20 + panelH];

    ui = PsychLVGLOpen(win, panelW, panelH, dst);
    closer = onCleanup(@() PsychLVGLClose(ui)); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    st = PsychLVGL('StyleCreate');
    PsychLVGL('StyleSetProp', st, 'bg_color', [255 0 0]);
    PsychLVGL('StyleSetProp', st, 'bg_opa', 255);
    PsychLVGL('StyleSetProp', st, 'radius', 0);
    PsychLVGL('StyleSetProp', st, 'border_width', 0);

    box = PsychLVGL('ObjCreate', scr);
    PsychLVGL('ObjSetPos', box, 0, 0);
    PsychLVGL('ObjSetSize', box, panelW, panelH);
    PsychLVGL('ObjAddStyle', box, st);

    m = frame_mean(win, ui, dst);
    plv_assert('the styled object is red', m(1) > 200 && m(2) < 60 && m(3) < 60);

    PsychLVGL('StyleSetProp', st, 'bg_color', [0 255 0]);
    m = frame_mean(win, ui, dst);
    plv_assert('a changed style redraws the object green', ...
               m(2) > 200 && m(1) < 60 && m(3) < 60);

    plv_throws('a style in use cannot be deleted', 'psychlvgl:InUse', ...
               @() PsychLVGL('StyleDelete', st));
    PsychLVGL('ObjRemoveStyle', box, st);
    PsychLVGL('StyleDelete', st);
    m = frame_mean(win, ui, dst);
    plv_assert('without the style the object is not green', ~(m(2) > 200 && m(1) < 60));
end

function m = frame_mean(win, ui, dst)
    PsychLVGLFrame(ui);
    img = double(Screen('GetImage', win, dst, 'drawBuffer'));
    Screen('Flip', win);
    inner = img(10:end-9, 10:end-9, :);
    m = squeeze(mean(mean(inner, 1), 2));
end
