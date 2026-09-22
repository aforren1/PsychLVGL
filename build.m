function build(varargin)
% BUILD  Compile the PsychLVGL MEX for MATLAB or Octave.
%
%   build             Build the GPU variant into dist/<arch>.
%   build test-sw     Build the software test variant into dist-sw/<arch>.
%   build test        Build the software variant, then run the no-GL tests.
%   build test-gl     Build the GPU variant, then run the GL tests. Needs
%                     Psychtoolbox and a GPU.
%   build gen         Run the binding generator (needs uv and a C compiler).
%   build clean       Remove the build and install directories.
%
%   The bundled LVGL is compiled with CMake against the project lv_conf.h,
%   then `mex` links the MEX against the resulting static libraries. Set
%   MEX_CMAKE_GENERATOR to override the CMake generator; on Windows the
%   "MinGW Makefiles" generator refuses to run while sh.exe is on PATH, so
%   Ninja is the better choice inside a Git Bash or MSYS2 shell.

    here = fileparts(mfilename('fullpath'));
    old = cd(here);
    restore = onCleanup(@() cd(old)); %#ok<NASGU>

    action = 'build';
    if nargin >= 1
        action = varargin{1};
    end

    switch lower(action)
        case 'clean'
            do_clean();
            return;
        case 'gen'
            do_gen(here);
            return;
        case 'test-sw'
            build_variant(here, true);
            return;
        case 'test'
            build_variant(here, true);
            addpath(fullfile(here, 'tests'));
            run_tests('sw');
            return;
        case 'test-gl'
            build_variant(here, false);
            addpath(fullfile(here, 'tests'));
            run_tests('gl');
            return;
        case 'compile-only'
            % What CI does for the GPU variant: prove the NanoVG and glad
            % paths compile and link on a machine with no GPU.
            build_variant(here, false);
            return;
        case 'build'
            build_variant(here, false);
            return;
        otherwise
            error('build:usage', 'unknown action "%s"', action);
    end
end

% ---------------------------------------------------------------- variants

function build_variant(here, sw)
    is_octave = exist('OCTAVE_VERSION', 'builtin') ~= 0;

    if is_octave
        engine = 'octave';
    else
        engine = 'matlab';
    end
    % Octave calls its MEX PsychLVGL.mex on every operating system, so the
    % build, install and output directories all carry the architecture.
    % PsychLVGLSetup owns the naming, because Octave's computer('arch')
    % answers with a GNU triplet instead of a MATLAB architecture name.
    addpath(fullfile(here, 'm'));
    arch = PsychLVGLSetup('arch');
    if ispc
        tag = engine;
    else
        tag = [engine '-' arch];
    end
    if sw
        builddir = ['build-' tag '-sw'];
        instdir  = ['inst-' tag '-sw'];
        outdir   = fullfile('dist-sw', arch);
    else
        builddir = ['build-' tag];
        instdir  = ['inst-' tag];
        outdir   = fullfile('dist', arch);
    end

    assert(exist(fullfile(here, 'third_party', 'lvgl', 'lvgl.h'), 'file') ~= 0, ...
           'build:lvgl', ['third_party/lvgl is missing. Clone LVGL v9.6.0 into it, ' ...
                          'see README.md.']);

    cc = engine_compiler(is_octave);
    [gen, genextra] = cmake_generator(is_octave);

    cfg = sprintf(['cmake -E chdir "%s" cmake -DCMAKE_BUILD_TYPE=Release ' ...
                   '-DCMAKE_INSTALL_PREFIX="%s" -DCMAKE_INSTALL_LIBDIR=lib ' ...
                   '-DPSYCHLVGL_TRACY=OFF -DPSYCHLVGL_TEST_SW=%s -Wno-dev'], ...
                  builddir, fullfile(here, instdir), upper(logical_str(sw)));
    if ~isempty(cc)
        cfg = [cfg sprintf(' -DCMAKE_C_COMPILER="%s"', strrep(cc, '\', '/'))];
    end
    if ~isempty(gen)
        cfg = [cfg sprintf(' -G "%s"', gen)];
        if ~isempty(strfind(gen, 'Visual Studio')) %#ok<STREMP>
            cfg = [cfg ' -A x64'];
        end
    end
    if ~isempty(genextra)
        cfg = [cfg ' ' genextra];
    end
    cfg = [cfg ' "' strrep(here, '\', '/') '"'];

    if ~exist(fullfile(here, builddir), 'dir'); mkdir(fullfile(here, builddir)); end
    if system(cfg) ~= 0
        fprintf('cmake configure failed; wiping %s and retrying once...\n', builddir);
        rmdir(fullfile(here, builddir), 's');
        mkdir(fullfile(here, builddir));
        run_cmd(cfg);
    end
    % LVGL is about 700 translation units, so a serial build dominates the
    % wall clock time of every build and of CI.
    run_cmd(sprintf('cmake --build "%s" --config Release --parallel', builddir));
    % `cmake --install` only copies. `cmake --build --target install` first
    % re-runs the whole dependency check, which over a bind mount into a
    % container costs minutes. Fall back for CMake older than 3.15.
    if system(sprintf('cmake --install "%s" --config Release', builddir)) ~= 0
        run_cmd(sprintf('cmake --build "%s" --target install --config Release', builddir));
    end

    check_toolchain(here, builddir, is_octave);

    libs = find_libs(here, instdir, is_octave);

    % --- compile the MEX ---
    % No -R2018a: the code uses only the classic mx* API, so one source builds
    % for both engines.
    if ~exist(fullfile(here, outdir), 'dir'); mkdir(fullfile(here, outdir)); end

    args = { ...
        ['-I' fullfile(here, 'src')], ...
        ['-I' fullfile(here, 'src', 'core')], ...
        ['-I' fullfile(here, 'third_party', 'lvgl')], ...
        ['-I' fullfile(here, 'third_party', 'lvgl', 'include')], ...
        ['-I' fullfile(here, 'third_party', 'lvgl', 'src', 'drivers', 'opengles', 'glad', 'include')], ...
        ... % LV_CONF_INCLUDE_SIMPLE rather than LV_CONF_PATH: mex does not
        ... % pass the quotes a path macro needs through to the compiler.
        ['-I' here], '-DLV_CONF_INCLUDE_SIMPLE', ...
        fullfile('src', 'psychlvgl.c'), ...
        fullfile('src', 'plv_marshal.c'), ...
        fullfile('src', 'psychlvgl_gen.c'), ...
        fullfile('src', 'psychlvgl_enums.c')};

    if is_octave
        args{end+1} = '-DPSYCHLVGL_OCTAVE=1';
    end
    if sw
        args{end+1} = '-DPSYCHLVGL_TEST_SW=1';
    end
    args = [args, libs(:)'];
    if ~sw
        if ispc
            args{end+1} = '-lopengl32';
        elseif ismac
            % OpenGL.framework carries both GL and CGL. It is deprecated since
            % macOS 10.14, and the two macros keep that from burying real
            % warnings.
            args{end+1} = '-DGL_SILENCE_DEPRECATION=1';
            args{end+1} = '-DCGL_SILENCE_DEPRECATION=1';
            if is_octave
                % mkoctfile answers "unrecognized argument" to LDFLAGS=... and
                % reads the environment variable instead, and that variable
                % replaces its own value rather than adding to it. Both
                % measured with `mkoctfile -v` on Octave 10.1. So read the
                % default back, append, and put it back afterwards.
                old_ldflags = getenv('LDFLAGS');
                restore_ldflags = onCleanup(@() plv_restore_env('LDFLAGS', old_ldflags)); %#ok<NASGU>
                setenv('LDFLAGS', [mkoctfile_var('LDFLAGS') ' -framework OpenGL']);
            else
                args{end+1} = 'LDFLAGS=$LDFLAGS -framework OpenGL';
            end
        else
            args{end+1} = '-lGL';
            args{end+1} = '-ldl';
        end
    end
    args{end+1} = '-output';
    args{end+1} = fullfile(outdir, 'PsychLVGL');

    mex(args{:});
    fprintf('build complete: %s\n', fullfile(outdir, ['PsychLVGL.' mexext]));
end

% ------------------------------------------------------------------ helpers

function s = logical_str(tf)
    if tf; s = 'on'; else; s = 'off'; end
end

function cc = engine_compiler(is_octave)
% The static library and the MEX must come from the same toolchain.
    cc = '';
    try
        if is_octave
            [status, out] = system('mkoctfile -p CC');
            if status == 0
                cc = strtrim(out);
            end
        else
            cfg = mex.getCompilerConfigurations('C', 'Selected');
            if ~isempty(cfg) && ~isempty(strfind(cfg(1).Name, 'Microsoft')) %#ok<STREMP>
                cc = '';   % the Visual Studio generator already picks cl.exe
            end
        end
    catch
        cc = '';
    end
    if ispc && is_octave && isempty(cc)
        cand = fullfile(octave_root(), 'mingw64', 'bin', 'gcc.exe');
        if exist(cand, 'file'); cc = cand; end
    end
end

function plv_restore_env(name, old)
% An empty value is not the same as no value: mkoctfile treats an LDFLAGS that
% is set but empty as "use nothing", which would break the next build in this
% session.
    if isempty(old)
        if exist('unsetenv', 'builtin') ~= 0 || exist('unsetenv', 'file') ~= 0
            unsetenv(name);
        else
            setenv(name, '');
        end
    else
        setenv(name, old);
    end
end

function v = mkoctfile_var(name)
% The value mkoctfile would use, so that a flag can be appended to it.
    v = '';
    try
        [status, out] = system(['mkoctfile -p ' name]);
        if status == 0
            v = strtrim(out);
        end
    catch
        v = '';
    end
end

function r = octave_root()
% The installation root, which holds mingw64/ (the compiler) and usr/ (make).
    r = '';
    if exist('OCTAVE_HOME', 'builtin') || exist('OCTAVE_HOME', 'file')
        try
            r = OCTAVE_HOME();
        catch
            r = '';
        end
    end
    if isempty(r) || ~exist(fullfile(r, 'mingw64'), 'dir')
        r = 'C:\Program Files\GNU Octave\Octave-10.1.0';
    end
end

function [gen, extra] = cmake_generator(is_octave)
    extra = '';
    gen = getenv('MEX_CMAKE_GENERATOR');
    if ~isempty(gen); return; end
    if ismac
        % Named rather than left to CMake: a machine with Xcode installed can
        % have CMAKE_GENERATOR set to Xcode, and the Xcode generator puts the
        % archives under a per-configuration directory that find_libs does not
        % look in.
        gen = 'Unix Makefiles';
        return;
    end
    if ~ispc
        gen = '';
        return;
    end
    if ~is_octave
        gen = 'Visual Studio 17 2022';
        return;
    end

    % "MinGW Makefiles" refuses to run while sh.exe is on PATH, and the Octave
    % distribution ships both sh.exe and make.exe in its MSYS tree, so the MSYS
    % generator is the one that matches what is installed. Ninja wins when it
    % is there.
    if system('ninja --version >NUL 2>NUL') == 0
        gen = 'Ninja';
        return;
    end
    mk = fullfile(octave_root(), 'usr', 'bin', 'make.exe');
    if exist(mk, 'file')
        gen = 'MSYS Makefiles';
        extra = sprintf('-DCMAKE_MAKE_PROGRAM="%s"', strrep(mk, '\', '/'));
    else
        gen = 'MinGW Makefiles';
    end
end

function check_toolchain(here, builddir, is_octave)
    idfile = fullfile(here, builddir, 'plv_toolchain_id.txt');
    if exist(idfile, 'file') == 0
        warning('build:toolchain', 'no toolchain marker in %s', builddir);
        return;
    end
    fid = fopen(idfile, 'r');
    id = strtrim(fread(fid, '*char')');
    fclose(fid);
    % Only MATLAB on Windows links with MSVC. MATLAB on Linux uses GCC and on
    % macOS Clang, the same families Octave uses everywhere, so a GNU or Clang
    % library is right for every engine except MATLAB on Windows.
    if is_octave || ~ispc
        want = {'GNU', 'Clang', 'AppleClang'};
    else
        want = {'MSVC'};
    end
    if ~any(strcmp(id, want))
        error('build:toolchain', ...
              ['the static library was built with %s but this engine links with %s. ' ...
               'Delete %s and rebuild, or set MEX_CMAKE_GENERATOR.'], id, strjoin(want, ' or '), builddir);
    end
end

function libs = find_libs(here, instdir, is_octave)
    libdir = fullfile(here, instdir, 'lib');
    if is_octave || ~ispc
        names = {'libplv_core.a', 'liblvgl.a'};
    else
        names = {'plv_core.lib', 'lvgl.lib'};
    end
    libs = cell(1, numel(names));
    for k = 1:numel(names)
        libs{k} = fullfile(libdir, names{k});
        assert(exist(libs{k}, 'file') ~= 0, 'build:lib', ...
               'static library not found: %s', libs{k});
    end
end

function do_clean()
    d = dir('.');
    for k = 1:numel(d)
        if d(k).isdir && (strncmp(d(k).name, 'build-', 6) || strncmp(d(k).name, 'inst-', 5))
            rmdir(d(k).name, 's');
        end
    end
    fprintf('cleaned build and install directories\n');
end

function do_gen(here)
    uv = getenv('UV');
    if isempty(uv)
        uv = 'uv';
        if ispc && exist(fullfile(getenv('USERPROFILE'), '.local', 'bin', 'uv.exe'), 'file')
            uv = fullfile(getenv('USERPROFILE'), '.local', 'bin', 'uv.exe');
        end
    end
    cmd = sprintf('"%s" run --project "%s" python "%s"', uv, ...
                  fullfile(here, 'gen'), fullfile(here, 'gen', 'generate.py'));
    run_cmd(cmd);
end

function run_cmd(cmd)
    status = system(cmd);
    assert(status == 0, 'build:cmd', 'command failed (status %d): %s', status, cmd);
end
