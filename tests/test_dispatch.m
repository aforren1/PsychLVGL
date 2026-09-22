function test_dispatch()
% TEST_DISPATCH  Subcommand lookup, the opcode path, and argument errors.

    plv_throws('unknown name', 'psychlvgl:UnknownCommand', ...
               @() PsychLVGL('NoSuchSubcommand'));
    plv_throws('opcode out of range', 'psychlvgl:UnknownCommand', ...
               @() PsychLVGL(999999));
    plv_throws('call before Init', 'psychlvgl:NotInitialized', ...
               @() PsychLVGL('ScreenActive'));

    v = PsychLVGL('Version');
    plv_assert('Version is a struct', isstruct(v) && isfield(v, 'lvgl'));
    plv_assert('Version reports the build variant', ...
               any(strcmp(v.build, {'gl', 'test-sw'})));

    PsychLVGL('Init', 120, 90);
    c = onCleanup(@() PsychLVGL('Shutdown')); %#ok<NASGU>

    plv_throws('Init twice at the same size', 'psychlvgl:AlreadyInitialized', ...
               @() PsychLVGL('Init', 120, 90));

    scr = PsychLVGL('ScreenActive');
    plv_assert('ScreenActive returns a handle', isnumeric(scr) && scr > 0);

    % the opcode fast path reaches the same handler as the name
    op = PsychLVGL('Opcode', 'ObjGetWidth');
    plv_assert('Opcode is a positive integer', op > 0 && op == fix(op));
    w1 = PsychLVGL('ObjGetWidth', scr);
    w2 = PsychLVGL(op, scr);
    plv_eq('opcode path matches the name path', w1, w2);
    plv_eq('screen width is the panel width', w1, 120);

    ops = PsychLVGLOp();
    plv_eq('PsychLVGLOp agrees with Opcode', ops.ObjGetWidth, op);
    plv_eq('PsychLVGLOp Init is opcode 1', ops.Init, 1);

    plv_throws('too few arguments', 'psychlvgl:Usage', ...
               @() PsychLVGL('ObjSetSize', scr));
    plv_throws('too many arguments', 'psychlvgl:Usage', ...
               @() PsychLVGL('ObjSetSize', scr, 1, 2, 3));
    plv_throws('char where a handle is wanted', 'psychlvgl:Type', ...
               @() PsychLVGL('ObjGetWidth', 'scr'));
    plv_throws('out of range integer', 'psychlvgl:Range', ...
               @() PsychLVGL('ObjSetStyleBgOpa', scr, 300));
    plv_throws('unknown enum name', 'psychlvgl:Enum', ...
               @() PsychLVGL('ObjAlign', scr, 'NOT_AN_ALIGNMENT', 0, 0));
    plv_throws('unknown font', 'psychlvgl:Font', ...
               @() PsychLVGL('ObjSetStyleTextFont', scr, 'no_such_font'));

    % enum names, with and without the prefix, and joined with a bar
    plv_eq('Enum with the prefix', PsychLVGL('Enum', 'LV_ALIGN_CENTER'), ...
           PsychLVGL('Enum', 'ALIGN_CENTER'));
    joined = PsychLVGL('Enum', 'LV_PART_MAIN|LV_STATE_PRESSED');
    plv_eq('Enum joins names', joined, ...
           PsychLVGL('Enum', 'LV_PART_MAIN') + PsychLVGL('Enum', 'LV_STATE_PRESSED'));

    fonts = PsychLVGL('FontList');
    plv_assert('FontList is a cellstr', iscell(fonts) && ~isempty(fonts));
    plv_assert('FontList holds montserrat_16', any(strcmp(fonts, 'montserrat_16')));

    name = PsychLVGL('EventName', PsychLVGL('Enum', 'LV_EVENT_CLICKED'));
    plv_eq('EventName reverses the code', name, 'CLICKED');

    s = PsychLVGL('Stats');
    plv_assert('Stats has updateCount', isstruct(s) && isfield(s, 'updateCount'));
    plv_assert('Stats counts dispatched calls', ~isempty(s.opNames));
    PsychLVGL('Stats', 'reset');
    s2 = PsychLVGL('Stats');
    plv_eq('Stats reset clears the counters', s2.updateCount, 0);
end
