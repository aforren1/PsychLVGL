function test_gl_xml()
% TEST_GL_XML  An XML screen loaded into a Psychtoolbox window: the color
%   of a style from globals.xml reaches the screen, and a label holds the
%   text of a constant. The same file as the no-GL test_xml_load, rendered
%   by NanoVG.

    if ~plv_gl_available(); plv_gl_skip('test_gl_xml'); return; end

    fx = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'xml');
    win = ptb_test_window();
    panelW = 480; panelH = 480;
    dst = [0 0 panelW panelH];
    ui = PsychLVGLOpen(win, panelW, panelH, dst);
    closer = onCleanup(@() PsychLVGLClose(ui)); %#ok<NASGU>

    plv_xml_collect('reset');
    [root, n] = PsychLVGLLoadXML(fullfile(fx, 'main.xml'), [], struct('Warn', @plv_xml_collect));
    plv_assert('the screen fills the active screen', root == PsychLVGL('ScreenActive'));
    plv_eq('a label holds the text of a constant', PsychLVGL('LabelGetText', n.title), 'Fixture title');
    plv_assert('no warnings', isempty(plv_xml_collect('get')));

    PsychLVGLFrame(ui);
    PsychLVGLFrame(ui);
    img = double(Screen('GetImage', win, dst, 'drawBuffer'));
    Screen('Flip', win);

    % The card is at (4, 40), 200x80, filled with #accent 0x3366ff through
    % style_card; its label is in the middle, so sample its left part.
    card = img(40 + (15:30), 4 + (12:40), :);
    m = squeeze(mean(mean(card, 1), 2))';
    plv_assert(sprintf('the card has the color of #accent (mean [%.0f %.0f %.0f])', m), ...
               all(abs(m - [51 102 255]) < 20));

    % The view's own style: the screen background is 0x202020 where nothing
    % else is drawn.
    bg = img(310:390, 390:470, :);
    m = squeeze(mean(mean(bg, 1), 2))';
    plv_assert(sprintf('the screen background is 0x202020 (mean [%.0f %.0f %.0f])', m), ...
               all(abs(m - 32) < 12));

    % The title uses the TTF font of <fonts> and white text: bright pixels in
    % its box on a dark background.
    tw = PsychLVGL('ObjGetWidth', n.title);
    th = PsychLVGL('ObjGetHeight', n.title);
    title = img(2 + (1:th), 4 + (1:tw), :);
    plv_assert('the title is drawn in light text', max(title(:)) > 200 && th >= 24);

    % A subject pushed from the script changes what is drawn: the pressed
    % state of the card applies style_wide.
    PsychLVGL('ObjAddState', n.card, 'LV_STATE_PRESSED');
    PsychLVGLFrame(ui);
    img = double(Screen('GetImage', win, dst, 'drawBuffer'));
    Screen('Flip', win);
    edge = img(40 + (15:30), 4 + (170:195), :);
    m = squeeze(mean(mean(edge, 1), 2))';
    plv_assert('selector="pressed" narrows the card to 150 px on screen', all(abs(m - 32) < 20));
end
