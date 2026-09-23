function test_fonts()
% TEST_FONTS  TTF fonts through tiny_ttf: FontLoad handles wherever a font
%   name is accepted, and the rule that a font still named by a style cannot
%   be deleted.

    here = fileparts(mfilename('fullpath'));
    ttf = fullfile(fileparts(here), 'third_party', 'lvgl', 'examples', 'libs', ...
                   'tiny_ttf', 'Ubuntu-Medium.ttf');
    if ~exist(ttf, 'file')
        fprintf('   skipped: %s is missing\n', ttf);
        return;
    end

    PsychLVGL('Init', 200, 80);
    c = onCleanup(@() PsychLVGL('Shutdown')); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    lbl = PsychLVGL('LabelCreate', scr);
    PsychLVGL('LabelSetText', lbl, 'Tiny TTF');
    PsychLVGL('ObjAlign', lbl, 'LV_ALIGN_CENTER', 0, 0);
    builtin = render_crc();

    f = PsychLVGL('FontLoad', ttf, 28);
    plv_assert('a font handle is valid', PsychLVGL('IsValid', f));
    plv_assert('a font handle is above the object handle range', f >= 2^32);

    % a handle works wherever a font name does
    PsychLVGL('ObjSetStyleTextFont', lbl, f);
    ttfcrc = render_crc();
    plv_assert('the TTF font changes the rendered frame', ttfcrc ~= builtin);
    plv_assert('the label grows with a 28 px font', PsychLVGL('ObjGetHeight', lbl) >= 28);

    plv_throws('a font named by an object cannot be deleted', 'psychlvgl:InUse', ...
               @() PsychLVGL('FontDelete', f));
    PsychLVGL('ObjSetStyleTextFont', lbl, 'montserrat_16');
    plv_eq('a built-in name still works and restores the frame', render_crc(), builtin);

    st = PsychLVGL('StyleCreate');
    PsychLVGL('StyleSetProp', st, 'text_font', f);
    plv_throws('a font named by a style cannot be deleted, even unused', ...
               'psychlvgl:InUse', @() PsychLVGL('FontDelete', f));
    % A local style outranks an added one, so the style goes on a fresh
    % label that has no local font.
    PsychLVGL('ObjDelete', lbl);
    lbl = PsychLVGL('LabelCreate', scr);
    PsychLVGL('LabelSetText', lbl, 'Tiny TTF');
    PsychLVGL('ObjAlign', lbl, 'LV_ALIGN_CENTER', 0, 0);
    PsychLVGL('ObjAddStyle', lbl, st);
    plv_eq('a font through a style renders like a local one', render_crc(), ttfcrc);
    PsychLVGL('ObjRemoveStyle', lbl, st);
    PsychLVGL('StyleDelete', st);

    PsychLVGL('FontDelete', f);
    plv_assert('FontDelete frees the handle', ~PsychLVGL('IsValid', f));
    plv_throws('a deleted font raises InvalidHandle', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ObjSetStyleTextFont', lbl, f));
    plv_throws('a style handle is not a font', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ObjSetStyleTextFont', lbl, PsychLVGL('StyleCreate')));

    % load errors
    plv_throws('a missing file is a Font error', 'psychlvgl:Font', ...
               @() PsychLVGL('FontLoad', fullfile(here, 'no_such_font.ttf'), 16));
    plv_throws('a file that is not a font is a Font error', 'psychlvgl:Font', ...
               @() PsychLVGL('FontLoad', fullfile(here, 'run_tests.m'), 16));
    plv_throws('a size of 0 px is a Range error', 'psychlvgl:Range', ...
               @() PsychLVGL('FontLoad', ttf, 0));
    plv_throws('the path must be char', 'psychlvgl:Type', ...
               @() PsychLVGL('FontLoad', 42, 16));

    % Shutdown frees a font that a label still uses
    f2 = PsychLVGL('FontLoad', ttf, 14);
    PsychLVGL('ObjSetStyleTextFont', lbl, f2);
    render_crc();
    PsychLVGL('Shutdown');
    PsychLVGL('Init', 200, 80);
    plv_assert('font handles do not survive Shutdown', ~PsychLVGL('IsValid', f2));
end

function crc = render_crc()
    persistent t
    if isempty(t); t = 5000; end
    t = t + 1;
    PsychLVGL('Update', t, [0 0 0], 0, zeros(0, 2));
    t = t + 1;
    PsychLVGL('Update', t, [0 0 0], 0, zeros(0, 2));
    crc = PsychLVGL('FrameChecksum');
end
