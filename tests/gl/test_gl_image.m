function test_gl_image()
% TEST_GL_IMAGE  A Psychtoolbox texture drawn as an LVGL image through
%   PsychLVGLImageFromTexture, the right way up, with no pixel copy.

    if ~plv_gl_available(); plv_gl_skip('test_gl_image'); return; end

    win = ptb_test_window();
    panelW = 200; panelH = 120;
    dst = [20 20 20 + panelW 20 + panelH];

    ui = PsychLVGLOpen(win, panelW, panelH, dst);
    closer = onCleanup(@() PsychLVGLClose(ui)); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    PsychLVGL('ObjSetStyleBgColor', scr, [0 0 0]);
    PsychLVGL('ObjSetStyleBgOpa', scr, 255);

    % top half blue, bottom half red
    M = zeros(60, 80, 3, 'uint8');
    M(1:30, :, 3) = 255;
    M(31:60, :, 1) = 255;

    plv_throws('a rectangle texture is refused', 'psychlvgl:Texture', ...
               @() try_texture(win, Screen('MakeTexture', win, M)));
    plv_throws('a transposed texture is refused', 'psychlvgl:Texture', ...
               @() try_texture(win, Screen('MakeTexture', win, M, [], 1)));

    tex = Screen('MakeTexture', win, M, [], 1, [], 1);
    img = PsychLVGLImageFromTexture(win, tex);
    obj = PsychLVGL('ImageCreate', scr);
    PsychLVGL('ImageSetSrc', obj, img);
    PsychLVGL('ObjSetPos', obj, 0, 0);
    plv_eq('the image has the texture size', ...
           [PsychLVGL('ImageGetSrcWidth', obj), PsychLVGL('ImageGetSrcHeight', obj)], [80 60]);

    PsychLVGLFrame(ui);
    I = double(Screen('GetImage', win, dst, 'drawBuffer'));
    Screen('Flip', win);

    top = squeeze(mean(mean(I(6:24, 10:70, :), 1), 2));
    bot = squeeze(mean(mean(I(36:54, 10:70, :), 1), 2));
    plv_assert('the texture image is visible, top half blue', ...
               top(3) > 200 && top(1) < 60 && top(2) < 60);
    plv_assert('the texture image is upright, bottom half red', ...
               bot(1) > 200 && bot(2) < 60 && bot(3) < 60);
    right = squeeze(mean(mean(I(10:50, 120:190, :), 1), 2));
    plv_assert('the panel outside the image stays black', all(right < 30));

    plv_throws('an image in use cannot be deleted', 'psychlvgl:InUse', ...
               @() PsychLVGL('ImageDelete', img));
    PsychLVGL('ImageSetSrc', obj, 0);
    PsychLVGL('ImageDelete', img);
    Screen('Close', tex);
    PsychLVGLFrame(ui);
    Screen('Flip', win);
    plv_eq('the frame after ImageDelete left 2D mode', plv_gl_drawmode(), 0);

    % an image from a uint8 array goes through NanoVG's own upload path
    G = zeros(40, 50, 3, 'uint8');
    G(:, :, 2) = 255;
    arr = PsychLVGL('ImageFromArray', G);
    PsychLVGL('ImageSetSrc', obj, arr);
    PsychLVGL('ObjSetPos', obj, 120, 60);
    PsychLVGLFrame(ui);
    I = double(Screen('GetImage', win, dst, 'drawBuffer'));
    Screen('Flip', win);
    g = squeeze(mean(mean(I(70:90, 130:160, :), 1), 2));
    plv_assert('an ImageFromArray image is drawn on the GPU', ...
               g(2) > 200 && g(1) < 60 && g(3) < 60);
end

function try_texture(win, tex)
    closer = onCleanup(@() Screen('Close', tex)); %#ok<NASGU>
    PsychLVGLImageFromTexture(win, tex);
end
