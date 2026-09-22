function T = PsychLVGLPerf(sizes, counts)
% PSYCHLVGLPERF  Sweeps panel sizes and widget counts and prints one table.
%
%   PsychLVGLPerf
%   T = PsychLVGLPerf(sizes, counts)
%       sizes   Nx2 panel sizes in pixels, default [200 200; 640 480; 1920 1080]
%       counts  1xM widget counts, default [10 100 500]
%
%   For each cell the table holds the cost of one wrapped Update when nothing
%   changed and when one slider moved, plus the cost of the two Psychtoolbox
%   context switches on their own. The first two numbers include those two
%   switches, because that is what a script pays per frame. Measure before
%   optimizing: SPEC section 9.4 lists these as the first numbers to look at.
%
%   Needs Psychtoolbox and the GPU build.

    if nargin < 1 || isempty(sizes)
        sizes = [200 200; 640 480; 1920 1080];
    end
    if nargin < 2 || isempty(counts)
        counts = [10 100 500];
    end

    if exist('Screen', 'file') ~= 3
        error('psychlvgl:NoPTB', 'PsychLVGLPerf needs Psychtoolbox.');
    end
    % Both path entries go on before the first call into the MEX. The window
    % helper is shared with the GL tests and the demo, so the two development
    % preferences it sets live in one place.
    root = fileparts(fileparts(mfilename('fullpath')));
    addpath(fullfile(root, 'tests', 'gl'));
    PsychLVGLSetup();
    win = ptb_test_window([0 0 800 600]);
    closer = onCleanup(@() ptb_test_window_close()); %#ok<NASGU>

    rows = zeros(0, 6);
    fprintf('%6s %6s %8s %12s %12s %12s\n', ...
            'width', 'height', 'widgets', 'idle us', 'moving us', 'context us');

    for si = 1:size(sizes, 1)
        w = sizes(si, 1);
        h = sizes(si, 2);
        for ci = 1:numel(counts)
            n = counts(ci);
            [idleUs, moveUs, ctxUs] = one_cell(win, w, h, n);
            rows(end + 1, :) = [w h n idleUs moveUs ctxUs]; %#ok<AGROW>
            fprintf('%6d %6d %8d %12.1f %12.1f %12.1f\n', w, h, n, idleUs, moveUs, ctxUs);
        end
    end

    T = rows;
end

function [idleUs, moveUs, ctxUs] = one_cell(win, w, h, n)
    reps = 60;

    ui = PsychLVGLOpen(win, w, h, [0 0 w h]);
    guard = onCleanup(@() PsychLVGLClose(ui)); %#ok<NASGU>

    scr = PsychLVGL('ScreenActive');
    slider = PsychLVGL('SliderCreate', scr);
    PsychLVGL('ObjSetPos', slider, 4, 4);
    PsychLVGL('ObjSetSize', slider, max(40, w - 8), 16);
    PsychLVGL('SliderSetRange', slider, 0, 1000);

    for k = 2:n
        lbl = PsychLVGL('LabelCreate', scr);
        PsychLVGL('LabelSetText', lbl, sprintf('w%d', k));
        PsychLVGL('ObjSetPos', lbl, mod(k * 17, max(1, w - 30)), ...
                  30 + mod(k * 13, max(1, h - 40)));
    end

    t = GetSecs();
    for k = 1:3
        PsychLVGLGL(ui, 'Update', t + k * 0.016, [0 0 0], 0, zeros(0, 2));
    end

    % idle frames
    PsychLVGL('Stats', 'reset');
    t0 = GetSecs();
    for k = 1:reps
        PsychLVGLGL(ui, 'Update', t + (10 + k) * 0.016, [0 0 0], 0, zeros(0, 2));
    end
    idleUs = 1e6 * (GetSecs() - t0) / reps;

    % one slider value change per frame
    t0 = GetSecs();
    for k = 1:reps
        PsychLVGL('SliderSetValue', slider, mod(k * 7, 1000), 0);
        PsychLVGLGL(ui, 'Update', t + (100 + k) * 0.016, [0 0 0], 0, zeros(0, 2));
    end
    moveUs = 1e6 * (GetSecs() - t0) / reps;

    % the two context switches on their own
    t0 = GetSecs();
    for k = 1:reps
        Screen('BeginOpenGL', win);
        Screen('EndOpenGL', win);
    end
    ctxUs = 1e6 * (GetSecs() - t0) / reps;

    PsychLVGL('Poll');
end
