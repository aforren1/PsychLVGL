function run_tests(variant)
% RUN_TESTS  Test suite for the PsychLVGL MEX, MATLAB and Octave.
%
%   run_tests          The software variant in dist-sw/ if it is built, else
%                      the GPU variant in dist/.
%   run_tests sw       The no-GL suite on the software variant.
%   run_tests gl       The GL suite on the GPU variant; needs Psychtoolbox.
%
%   Only one of the two MEX files can be on the path, because both are called
%   PsychLVGL. Build them with `build test-sw` and `build`.

    global TST_PASS TST_FAIL %#ok<GVMIS>
    TST_PASS = 0;
    TST_FAIL = 0;

    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    addpath(fullfile(root, 'm'));
    swmex = fullfile(PsychLVGLSetup('distdir', 'sw'), ['PsychLVGL.' mexext]);

    if nargin < 1 || isempty(variant)
        if exist(swmex, 'file'); variant = 'sw'; else; variant = 'gl'; end
    end

    addpath(here);
    addpath(fullfile(here, 'gl'));

    % The Psychtoolbox stub goes on the path here, once, before the first call
    % into the MEX, and no test touches the path after that. Changing the load
    % path while the MEX is loaded sends Octave 10 into unbounded recursion in
    % out_of_date_check; SPEC deviation D35 has the backtrace.
    hadScreen = (exist('Screen', 'file') == 3);
    stub = fullfile(here, 'stub');
    if strcmp(variant, 'sw')
        addpath(stub);
    end

    PsychLVGLSetup(variant);

    v = PsychLVGL('Version');
    fprintf('psychlvgl %s, LVGL %s, build %s, NanoVG %s\n', ...
            v.psychlvgl, v.lvgl, v.build, v.nanovgBackend);

    if strcmp(variant, 'sw')
        run_group({'test_dispatch', 'test_handles', 'test_shutdown', 'test_events', 'test_keypad', ...
                   'test_tick', 'test_gen_marshal', 'test_checksum', ...
                   'test_chart', 'test_styles', 'test_fonts', 'test_images', ...
                   'test_helpers', 'test_xml_parse', 'test_xml_load', 'test_xml_subjects'});
        % Only hand the real Screen back where there is one. On a machine with
        % no Psychtoolbox the stub can stay: nothing else looks for Screen.
        if hadScreen
            rmpath(stub);
        end
        fprintf(['-- tests/gl skipped: they need the GPU variant. ' ...
                 'Run `build` then `run_tests gl` in a fresh session.\n']);
    elseif screen_works()
        % One window for the whole group: LVGL builds its NanoVG renderer once
        % per process and that renderer caches an OpenGL framebuffer name, so a
        % second GL context in the same session cannot be relied on.
        try
            run_group({'test_gl_init', 'test_gl_render', 'test_gl_click', ...
                       'test_gl_resize', 'test_gl_chart', 'test_gl_style', ...
                       'test_gl_image', 'test_gl_font', 'test_gl_demo_gabor', 'test_gl_xml'});
        catch err
            ptb_test_window_close();
            rethrow(err);
        end
        ptb_test_window_close();
    else
        fprintf('-- tests/gl skipped: Psychtoolbox Screen is not usable here\n');
    end

    fprintf('\n==== %d passed, %d failed ====\n', TST_PASS, TST_FAIL);
    if TST_FAIL > 0
        error('run_tests:failed', '%d test(s) failed', TST_FAIL);
    end
end

function run_group(names)
    global TST_FAIL %#ok<GVMIS>
    for k = 1:numel(names)
        fprintf('-- %s\n', names{k});
        try
            feval(names{k});
        catch err
            TST_FAIL = TST_FAIL + 1;
            fprintf(2, '  FAIL  %s threw %s: %s\n', names{k}, err.identifier, err.message);
        end
        cleanup_lvgl();
    end
end

function tf = screen_works()
% A source checkout of Psychtoolbox puts its M files on the path without a
% working Screen MEX, so ask Screen itself rather than trusting the path.
    tf = false;
    if exist('Screen', 'file') ~= 3; return; end
    try
        Screen('Version');
        tf = true;
    catch
        tf = false;
    end
end

function cleanup_lvgl()
% A test that threw part way through can leave LVGL initialized.
    try
        PsychLVGL('Shutdown');
    catch
        % nothing to shut down
    end
end
