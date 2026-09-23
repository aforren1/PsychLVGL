function out = PsychLVGLSetup(varargin)
% PSYCHLVGLSETUP  Puts PsychLVGL on the path for this engine and platform.
%
%   PsychLVGLSetup                 The GPU build in dist/<arch>.
%   PsychLVGLSetup('sw')           The software test build in dist-sw/<arch>.
%   PsychLVGLSetup('save')         The GPU build, then savepath, so the path
%                                  stays for later sessions.
%   PsychLVGLSetup('sw', 'save')   The same for the software test build.
%   PsychLVGLSetup('remove')       Takes dist/<arch>, dist-sw/<arch> and m/ of
%                                  this package off the path.
%   PsychLVGLSetup('remove', 'save')  The same, then savepath.
%   PsychLVGLSetup('nocheck', v)   Same paths, no check that the MEX is there.
%   a = PsychLVGLSetup('arch')     'win64', 'glnxa64', 'maci64' or 'maca64'.
%   d = PsychLVGLSetup('distdir', v)  The directory the MEX belongs in.
%
%   Octave names its MEX PsychLVGL.mex on every operating system, so the
%   builds are kept apart by architecture. m/ holds only the help text, so it
%   goes on the path before the MEX directory.
%
%   First use after you unzip a release, with nothing on the path yet:
%       cd C:\toolboxes\PsychLVGL
%       PsychLVGLSetup save
%
%   'remove' first unloads the MEX: it calls PsychLVGL('Shutdown') when the
%   MEX is locked, then clears it. Close the panel with PsychLVGLClose before,
%   so that Shutdown runs inside the OpenGL context. When the MEX stays
%   locked, 'remove' prints what to do and leaves the path as it is. Removing
%   a package that is not on the path does nothing.

    [args, save] = plv_take_save(varargin);
    mode = '';
    variant = '';
    if numel(args) >= 1; mode = args{1}; end
    if numel(args) >= 2; variant = args{2}; end
    if isempty(mode); mode = 'gl'; end

    % This file ships twice, byte for byte: at the package root, so that a
    % fresh unzip can call it before anything is on the path, and in m/, so
    % that scripts find it once m/ is on the path. A root wrapper that called
    % the m/ copy by name would call itself whenever the package root is the
    % current folder, because the current folder comes first. tests/test_setup
    % checks that the two copies stay identical.
    here = fileparts(mfilename('fullpath'));
    if exist(fullfile(here, 'm', 'PsychLVGLOpen.m'), 'file') ~= 0
        root = here;
    else
        root = fileparts(here);
    end

    switch lower(mode)
        case 'arch'
            out = plv_arch();
            return;
        case 'distdir'
            out = fullfile(root, plv_distname(variant), plv_arch());
            return;
        case 'nocheck'
            archdir = fullfile(root, plv_distname(variant), plv_arch());
            plv_ensure_order(fullfile(root, 'm'), archdir);
            plv_save(save, root);
            out = root;
            return;
        case 'remove'
            plv_remove(root, save);
            out = root;
            return;
        otherwise
            variant = mode;
    end

    archdir = fullfile(root, plv_distname(variant), plv_arch());
    mexfile = fullfile(archdir, ['PsychLVGL.' mexext]);

    if exist(mexfile, 'file') == 0
        if strcmp(plv_distname(variant), 'dist-sw')
            cmd = 'build test-sw';
        else
            cmd = 'build';
        end
        error('psychlvgl:NotBuilt', ...
              ['PsychLVGL is not built for this platform.\n' ...
               'Expected: %s\n' ...
               'Run %s from %s.'], mexfile, cmd, root);
    end

    plv_ensure_order(fullfile(root, 'm'), archdir);
    plv_save(save, root);
    out = root;
end

function [args, save] = plv_take_save(args)
% 'save' may come anywhere in the argument list, so PsychLVGLSetup save,
% PsychLVGLSetup sw save and PsychLVGLSetup remove save all read naturally.
    save = false;
    keep = true(size(args));
    for k = 1:numel(args)
        if ischar(args{k}) && strcmpi(args{k}, 'save')
            save = true;
            keep(k) = false;
        end
    end
    args = args(keep);
end

function plv_save(save, root)
    if ~save
        return;
    end
    if savepath() ~= 0
        warning('psychlvgl:SavePath', ...
                ['savepath could not write the path file. Add this line to ' ...
                 'your startup.m (MATLAB) or ~/.octaverc (Octave) instead:\n' ...
                 '    run(''%s'')'], fullfile(root, 'PsychLVGLSetup.m'));
    end
end

function plv_remove(root, save)
% The path changes only after the MEX is unloaded. A load path change while
% a locked MEX is loaded sends Octave 10 into unbounded recursion in
% out_of_date_check (SPEC deviation D35), so a MEX that stays locked stops the
% removal before any rmpath.
    dirs = {fullfile(root, 'dist', plv_arch()), ...
            fullfile(root, 'dist-sw', plv_arch()), ...
            fullfile(root, 'm')};
    onpath = false(size(dirs));
    for k = 1:numel(dirs)
        onpath(k) = plv_path_index(dirs{k}) > 0;
    end
    if ~any(onpath)
        return;
    end

    if mislocked('PsychLVGL')
        % Shutdown is the one subcommand that unlocks. Without an OpenGL
        % context it frees LVGL and leaves the texture to the context owner.
        try
            PsychLVGL('Shutdown');
        catch err
            fprintf(2, 'PsychLVGL(''Shutdown'') failed: %s\n', err.message);
        end
    end
    if mislocked('PsychLVGL')
        fprintf(2, ['PsychLVGL is still locked in memory, so the path was not ' ...
                    'changed.\nClose the panel with PsychLVGLClose(ui), or call ' ...
                    'PsychLVGL(''Shutdown''), then run PsychLVGLSetup remove again.\n' ...
                    'If that does not help, restart %s and run it before the first ' ...
                    'PsychLVGL call.\n'], plv_engine_name());
        return;
    end
    % Octave's plain clear leaves a loaded function in place, so the MEX
    % stayed resident and the rmpath below crashed Octave 10.1 on Linux
    % (the path-change-with-loaded-MEX class). -f clears functions.
    if exist('OCTAVE_VERSION', 'builtin') ~= 0
        clear('-f', 'PsychLVGL');
    else
        clear('PsychLVGL');
    end

    for k = find(onpath)
        rmpath(dirs{k});
    end
    plv_save(save, root);
end

function n = plv_engine_name()
    if exist('OCTAVE_VERSION', 'builtin') ~= 0
        n = 'Octave';
    else
        n = 'MATLAB';
    end
end

function plv_ensure_order(mdir, archdir)
% The contract is about order, not presence: dist/<arch> must come before m/,
% or m/PsychLVGL.m shadows the MEX and every call raises psychlvgl:NotBuilt.
% The path is changed only when that order does not hold, because a caller
% may run this on every frame and a load path change while the MEX is loaded
% sends Octave 10 into unbounded recursion in out_of_date_check (SPEC
% deviation D35). addpath prepends, so adding archdir last puts it in front.
    mi = plv_path_index(mdir);
    ai = plv_path_index(archdir);
    if mi == 0
        addpath(mdir);
        mi = plv_path_index(mdir);
    end
    if ai == 0 || ai > mi
        addpath(archdir);
    end
end

function i = plv_path_index(d)
% Position of d on the load path, or 0. Windows compares case insensitively.
    parts = strsplit(path(), pathsep());
    if ispc
        hit = find(strcmpi(parts, d), 1);
    else
        hit = find(strcmp(parts, d), 1);
    end
    if isempty(hit)
        i = 0;
    else
        i = hit;
    end
end

function d = plv_distname(variant)
    if isempty(variant); variant = 'gl'; end
    switch lower(variant)
        case {'gl', 'gpu'}
            d = 'dist';
        case {'sw', 'test-sw', 'software'}
            d = 'dist-sw';
        otherwise
            error('psychlvgl:Usage', 'unknown variant "%s"', variant);
    end
end

function a = plv_arch()
% Octave's computer('arch') returns a GNU triplet, not a MATLAB architecture
% name, so the name is derived from the platform predicates there.
    if exist('OCTAVE_VERSION', 'builtin') ~= 0
        if ispc
            a = 'win64';
        elseif ismac
            if ~isempty(strfind(lower(computer()), 'aarch64')) || ...
               ~isempty(strfind(lower(computer()), 'arm64')) %#ok<STREMP>
                a = 'maca64';
            else
                a = 'maci64';
            end
        else
            a = 'glnxa64';
        end
    else
        a = computer('arch');
    end
end
