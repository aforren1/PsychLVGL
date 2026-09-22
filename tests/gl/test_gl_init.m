function test_gl_init()
% TEST_GL_INIT  PsychLVGLOpen returns a wrapped panel, and Version reports the
%   NanoVG backend. Needs Psychtoolbox and a GPU.

    if ~plv_gl_available(); plv_gl_skip('test_gl_init'); return; end

    % Before any window exists nothing has made a GL context current on this
    % thread, so this is where the check can be observed. Once Psychtoolbox
    % opens a window its own context stays current on the main thread even
    % outside BeginOpenGL, so the MEX cannot tell the two apart there.
    plv_throws('Init with no GL context raises NoGLContext', ...
               'psychlvgl:NoGLContext', @() PsychLVGL('Init', 200, 200));

    win = ptb_test_window();

    ui = PsychLVGLOpen(win, 200, 200);

    plv_assert('Open returns a nonzero GL texture id', ui.glTex > 0);
    plv_assert('Open returns a Psychtoolbox texture', ui.tex > 0);
    plv_eq('Open keeps the panel size', [ui.w ui.h], [200 200]);
    plv_eq('the default rectangle is the top left corner', ui.dst, [0 0 200 200]);
    plv_eq('Open left Psychtoolbox in 2D mode', plv_gl_drawmode(), 0);

    v = PsychLVGL('Version');
    plv_eq('Version reports the GL build', v.build, 'gl');
    plv_assert('Version names the NanoVG backend', ...
               any(strcmp(v.nanovgBackend, {'GL2', 'GL3', 'GLES2', 'GLES3'})));
    plv_assert('Version reports the GL version', ~isempty(v.glVersion));
    plv_assert('Version reports the renderer', ~isempty(v.glRenderer));

    % A GL subcommand through the wrapper, and the state after it.
    dirty = PsychLVGLGL(ui, 'Update', GetSecs(), [0 0 0], 0, zeros(0, 2));
    plv_assert('the first Update renders', dirty == 1);
    plv_eq('the wrapper left 2D mode', plv_gl_drawmode(), 0);

    PsychLVGLClose(ui);
    plv_throws('Close shut the panel down', 'psychlvgl:NotInitialized', ...
               @() PsychLVGL('Poll'));
    PsychLVGLClose(ui);
    plv_assert('Close is safe twice', true);
end
