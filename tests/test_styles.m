function test_styles()
% TEST_STYLES  lv_style_t handles: create, set properties, add to objects,
%   and the rule that a style still added to an object cannot be deleted.

    PsychLVGL('Init', 160, 120);
    c = onCleanup(@() PsychLVGL('Shutdown')); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    obj = PsychLVGL('ObjCreate', scr);
    PsychLVGL('ObjSetSize', obj, 80, 60);

    st = PsychLVGL('StyleCreate');
    plv_assert('a style handle is valid', PsychLVGL('IsValid', st));
    plv_assert('a style handle is above the object handle range', st >= 2^32);

    % the property names of the ObjSetStyle<Prop> subcommands, in three spellings
    PsychLVGL('StyleSetProp', st, 'bg_color', [255 0 0]);
    PsychLVGL('StyleSetProp', st, 'BgOpa', 255);
    PsychLVGL('StyleSetProp', st, 'LV_STYLE_RADIUS', 0);
    PsychLVGL('StyleSetProp', st, 'border_width', 0);
    PsychLVGL('StyleSetProp', st, 'text_align', 'LV_TEXT_ALIGN_CENTER');
    PsychLVGL('StyleSetProp', st, 'text_font', 'montserrat_20');
    plv_assert('StyleSetProp takes every value class the obj setters take', true);

    plv_throws('an unknown property is an Enum error', 'psychlvgl:Enum', ...
               @() PsychLVGL('StyleSetProp', st, 'no_such_prop', 1));
    plv_throws('an opacity above 255 is a Range error', 'psychlvgl:Range', ...
               @() PsychLVGL('StyleSetProp', st, 'bg_opa', 300));
    plv_throws('a colour of the wrong shape is a Type error', 'psychlvgl:Type', ...
               @() PsychLVGL('StyleSetProp', st, 'bg_color', [1 2]));
    plv_throws('an unknown font is a Font error', 'psychlvgl:Font', ...
               @() PsychLVGL('StyleSetProp', st, 'text_font', 'no_font'));
    plv_throws('the property name must be char', 'psychlvgl:Type', ...
               @() PsychLVGL('StyleSetProp', st, 3, 1));
    plv_throws('an object handle is not a style', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('StyleSetProp', obj, 'bg_opa', 1));
    plv_throws('a style handle is not an object', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ObjGetWidth', st));

    % a style changes what the renderer draws
    base = render_crc();
    PsychLVGL('ObjAddStyle', obj, st);
    styled = render_crc();
    plv_assert('adding a style changes the rendered frame', styled ~= base);
    PsychLVGL('StyleSetProp', st, 'bg_color', [0 0 255]);
    recoloured = render_crc();
    plv_assert('changing a style in use redraws its objects', recoloured ~= styled);

    % delete rules
    plv_throws('a style added to an object cannot be deleted', 'psychlvgl:InUse', ...
               @() PsychLVGL('StyleDelete', st));
    plv_assert('the refused delete leaves the style valid', PsychLVGL('IsValid', st));
    PsychLVGL('ObjAddStyle', obj, st, 'LV_PART_MAIN|LV_STATE_PRESSED');
    PsychLVGL('ObjRemoveStyle', obj, st, 'LV_PART_MAIN');
    plv_throws('removing one selector keeps the other entry', 'psychlvgl:InUse', ...
               @() PsychLVGL('StyleDelete', st));
    PsychLVGL('ObjRemoveStyle', obj, st);
    PsychLVGL('StyleDelete', st);
    plv_assert('ObjRemoveStyle without a selector frees every entry', ~PsychLVGL('IsValid', st));
    plv_throws('a deleted style raises InvalidHandle', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGL('ObjAddStyle', obj, st));
    plv_eq('the frame is back to the unstyled one', render_crc(), base);

    % ObjRemoveStyleAll and object deletion free a style too
    s2 = PsychLVGL('StyleCreate');
    PsychLVGL('ObjAddStyle', obj, s2);
    PsychLVGL('ObjRemoveStyleAll', obj);
    PsychLVGL('StyleDelete', s2);
    plv_assert('ObjRemoveStyleAll releases the style', ~PsychLVGL('IsValid', s2));

    s3 = PsychLVGL('StyleCreate');
    kid = PsychLVGL('ObjCreate', obj);
    PsychLVGL('ObjAddStyle', kid, s3);
    PsychLVGL('ObjAddStyle', scr, s3, 'LV_PART_SCROLLBAR');
    PsychLVGL('ObjDelete', obj);
    plv_throws('the screen still uses the style', 'psychlvgl:InUse', ...
               @() PsychLVGL('StyleDelete', s3));
    PsychLVGL('ObjRemoveStyle', scr, 0, 'LV_PART_SCROLLBAR');
    PsychLVGL('StyleDelete', s3);
    plv_assert('a deleted object and style 0 release every use', ~PsychLVGL('IsValid', s3));

    % Shutdown frees styles that are still added to objects
    s4 = PsychLVGL('StyleCreate');
    PsychLVGL('StyleSetProp', s4, 'bg_color', [0 255 0]);
    PsychLVGL('ObjAddStyle', scr, s4);
    PsychLVGL('Update', 20, [0 0 0], 0, zeros(0, 2));
    PsychLVGL('Shutdown');
    PsychLVGL('Init', 160, 120);
    plv_assert('style handles do not survive Shutdown', ~PsychLVGL('IsValid', s4));
    PsychLVGL('Update', 21, [0 0 0], 0, zeros(0, 2));
    plv_assert('the next session renders after a styled Shutdown', true);
end

function crc = render_crc()
% Two Updates, far enough apart for any redraw to land in the buffer.
    persistent t
    if isempty(t); t = 1000; end
    t = t + 1;
    PsychLVGL('Update', t, [0 0 0], 0, zeros(0, 2));
    t = t + 1;
    PsychLVGL('Update', t, [0 0 0], 0, zeros(0, 2));
    crc = PsychLVGL('FrameChecksum');
end
