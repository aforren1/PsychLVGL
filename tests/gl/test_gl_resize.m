function test_gl_resize()
% TEST_GL_RESIZE  Init at a new size returns a new texture and invalidates the
%   old handles (SPEC rule R5).

    if ~plv_gl_available(); plv_gl_skip('test_gl_resize'); return; end

    win = ptb_test_window();

    Screen('BeginOpenGL', win);
    tex1 = PsychLVGL('Init', 200, 120);
    Screen('EndOpenGL', win);
    scr = PsychLVGL('ScreenActive');
    old = PsychLVGL('ObjCreate', scr);

    Screen('BeginOpenGL', win);
    tex2 = PsychLVGL('Init', 240, 160);
    Screen('EndOpenGL', win);

    plv_assert('a new size gives a new texture id', tex2 ~= tex1);
    plv_assert('old handles are invalid', ~PsychLVGL('IsValid', old));

    global GL %#ok<GVMIS>
    ptex = Screen('SetOpenGLTexture', win, [], tex2, GL.TEXTURE_2D, 240, 160);
    scr = PsychLVGL('ScreenActive');
    PsychLVGL('ObjSetStyleBgColor', scr, [0 255 0]);

    Screen('BeginOpenGL', win);
    PsychLVGL('Update', GetSecs(), [0 0 0], 0, zeros(0, 2));
    Screen('EndOpenGL', win);
    Screen('DrawTexture', win, ptex, [], [10 10 250 170]);
    img = double(Screen('GetImage', win, [10 10 250 170], 'drawBuffer'));
    Screen('Flip', win);

    m = squeeze(mean(mean(img, 1), 2));
    plv_assert('the re-wrapped texture draws', m(2) > m(1) + 40);

    Screen('BeginOpenGL', win);
    PsychLVGL('Shutdown');
    Screen('EndOpenGL', win);
end
