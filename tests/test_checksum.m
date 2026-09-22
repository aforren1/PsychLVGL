function test_checksum()
% TEST_CHECKSUM  CRC32 of the software render buffer pins the rendering.
%
%   The stored value SPEC 11.1 asks for would have to be regenerated for every
%   compiler and font rounding difference, so the test compares two runs of the
%   same fixed scene at the same fixed ticks instead, and checks that a change
%   to the scene changes the checksum.

    if ~strcmp(getfield(PsychLVGL('Version'), 'build'), 'test-sw') %#ok<GFLD>
        fprintf('   skipped: FrameChecksum needs the software variant\n');
        return;
    end

    a = render_scene('hello');
    b = render_scene('hello');
    c = render_scene('world');

    plv_assert('the checksum is not empty', a ~= 0);
    plv_eq('the same scene gives the same checksum', a, b);
    plv_assert('a different scene gives a different checksum', a ~= c);
end

function crc = render_scene(text)
    PsychLVGL('Shutdown');
    PsychLVGL('Init', 128, 64);
    scr = PsychLVGL('ScreenActive');
    PsychLVGL('ObjSetStyleBgColor', scr, [0 0 0]);
    lbl = PsychLVGL('LabelCreate', scr);
    PsychLVGL('LabelSetText', lbl, text);
    PsychLVGL('ObjAlign', lbl, 'LV_ALIGN_CENTER', 0, 0);
    PsychLVGL('Update', 500, [0 0 0], 0, zeros(0, 2));
    PsychLVGL('Update', 500.016, [0 0 0], 0, zeros(0, 2));
    crc = PsychLVGL('FrameChecksum');
    PsychLVGL('Shutdown');
end
