function out = PsychLVGLSetup(mode, variant)
% PSYCHLVGLSETUP  Puts PsychLVGL on the path for this engine and platform.
%
%   PsychLVGLSetup                 The GPU build in dist/<arch>.
%   PsychLVGLSetup('sw')           The software test build in dist-sw/<arch>.
%   PsychLVGLSetup('nocheck', v)   Same paths, no check that the MEX is there.
%   a = PsychLVGLSetup('arch')     'win64', 'glnxa64', 'maci64' or 'maca64'.
%   d = PsychLVGLSetup('distdir', v)  The directory the MEX belongs in.
%
%   Octave names its MEX PsychLVGL.mex on every operating system, so the
%   builds are kept apart by architecture. m/ holds only the help text, so it
%   goes on the path before the MEX directory.

    if nargin < 1 || isempty(mode);    mode = 'gl';  end
    if nargin < 2 || isempty(variant); variant = ''; end

    root = fileparts(fileparts(mfilename('fullpath')));

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
    out = root;
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
