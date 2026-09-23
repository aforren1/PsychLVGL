function test_gl_font()
% TEST_GL_FONT  A label in a TTF font loaded with FontLoad renders glyphs
%   through the NanoVG text path.

    if ~plv_gl_available(); plv_gl_skip('test_gl_font'); return; end

    here = fileparts(mfilename('fullpath'));
    ttf = fullfile(fileparts(here), 'xml', 'fonts', 'Ubuntu-Medium.ttf');
    if ~exist(ttf, 'file')
        fprintf('   test_gl_font skipped: %s is missing\n', ttf);
        return;
    end

    win = ptb_test_window();
    panelW = 240; panelH = 100;
    dst = [20 20 20 + panelW 20 + panelH];

    ui = PsychLVGLOpen(win, panelW, panelH, dst);
    closer = onCleanup(@() PsychLVGLClose(ui)); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    PsychLVGL('ObjSetStyleBgColor', scr, [0 0 0]);
    PsychLVGL('ObjSetStyleBgOpa', scr, 255);
    lbl = PsychLVGL('LabelCreate', scr);
    PsychLVGL('LabelSetText', lbl, 'Hg TTF');
    PsychLVGL('ObjSetStyleTextColor', lbl, [255 255 255]);
    PsychLVGL('ObjCenter', lbl);

    small = white_pixels(win, ui, dst);

    f = PsychLVGL('FontLoad', ttf, 48);
    PsychLVGL('ObjSetStyleTextFont', lbl, f);
    big = white_pixels(win, ui, dst);

    plv_assert('the TTF label renders glyphs', big > 200);
    plv_assert('the 48 px TTF text covers more than the 16 px built-in font', big > 2 * small);
    plv_assert('the label is as tall as the font', PsychLVGL('ObjGetHeight', lbl) >= 48);

    PsychLVGL('ObjDelete', lbl);
    PsychLVGL('FontDelete', f);
    plv_assert('FontDelete after the label is gone frees the handle', ~PsychLVGL('IsValid', f));
end

function n = white_pixels(win, ui, dst)
    PsychLVGLFrame(ui);
    img = double(Screen('GetImage', win, dst, 'drawBuffer'));
    Screen('Flip', win);
    n = sum(sum(all(img > 200, 3)));
end
