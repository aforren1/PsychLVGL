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

    % Quadrants: top left blue, top right cyan, bottom left red, bottom right
    % yellow. A transpose and a flip give different layouts, so checking all
    % four tells them apart.
    M = zeros(60, 80, 3, 'uint8');
    M(1:30, :, 3) = 255;
    M(31:60, :, 1) = 255;
    M(:, 41:80, 2) = 255;

    plv_throws('a rectangle texture is refused', 'psychlvgl:Texture', ...
               @() try_texture(win, Screen('MakeTexture', win, M)));

    % The default storage order is transposed; textureOrientation 1 is
    % upright. Both have to show the matrix as Screen('DrawTexture') does.
    texT = Screen('MakeTexture', win, M, [], 1);
    texU = Screen('MakeTexture', win, M, [], 1, [], 1);
    imgT = PsychLVGLImageFromTexture(win, texT);
    imgU = PsychLVGLImageFromTexture(win, texU);
    objT = PsychLVGL('ImageCreate', scr);
    objU = PsychLVGL('ImageCreate', scr);
    PsychLVGL('ImageSetSrc', objT, imgT);
    PsychLVGL('ImageSetSrc', objU, imgU);
    PsychLVGL('ObjSetPos', objT, 0, 0);
    PsychLVGL('ObjSetPos', objU, 100, 0);
    plv_eq('a transposed texture image has the matrix size', ...
           [PsychLVGL('ImageGetSrcWidth', objT), PsychLVGL('ImageGetSrcHeight', objT)], [80 60]);
    plv_eq('an upright texture image has the matrix size', ...
           [PsychLVGL('ImageGetSrcWidth', objU), PsychLVGL('ImageGetSrcHeight', objU)], [80 60]);

    PsychLVGLFrame(ui);
    I = double(Screen('GetImage', win, dst, 'drawBuffer'));
    Screen('Flip', win);

    names = {'transposed', 'upright'};
    x0 = [0 100];
    want = {[0 0 255], [0 255 255]; [255 0 0], [255 255 0]};
    where = {'top left', 'top right'; 'bottom left', 'bottom right'};
    for k = 1:2
        for r = 1:2
            for c = 1:2
                rows = (r - 1) * 30 + (8:22);
                cols = x0(k) + (c - 1) * 40 + (10:30);
                m = squeeze(mean(mean(I(rows, cols, :), 1), 2))';
                plv_assert(sprintf('the %s texture shows %s as the matrix does', ...
                                   names{k}, where{r, c}), all(abs(m - want{r, c}) < 60));
            end
        end
    end
    below = squeeze(mean(mean(I(70:115, 10:190, :), 1), 2));
    plv_assert('the panel outside the images stays black', all(below < 30));

    plv_throws('an image in use cannot be deleted', 'psychlvgl:InUse', ...
               @() PsychLVGL('ImageDelete', imgT));
    PsychLVGL('ImageSetSrc', objT, 0);
    PsychLVGL('ImageSetSrc', objU, 0);
    PsychLVGL('ImageDelete', imgT);
    PsychLVGL('ImageDelete', imgU);
    Screen('Close', texT);
    Screen('Close', texU);
    PsychLVGLFrame(ui);
    Screen('Flip', win);
    plv_eq('the frame after ImageDelete left 2D mode', plv_gl_drawmode(), 0);
    obj = objT;

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
