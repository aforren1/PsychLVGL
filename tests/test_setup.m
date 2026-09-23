function test_setup()
% TEST_SETUP  The two copies of PsychLVGLSetup, and its remove mode.
%
%   A release zip carries PsychLVGLSetup.m at its root, so that a fresh unzip
%   can call it with nothing on the path, and in m/, so that scripts find it
%   later. A wrapper cannot replace one copy: it would call itself whenever
%   the package root is the current folder. The copies must stay identical.
%
%   This is the one test that changes the load path, and it must run last in
%   the no-GL group. PsychLVGLSetup('remove') unloads the MEX before its first
%   rmpath, which is the point under test: a path change while the locked MEX
%   is loaded sends Octave 10 into unbounded recursion (SPEC deviation D35).
%   The test puts the software build back on the path at the end, with the
%   MEX still unloaded. It never calls savepath.

    here = fileparts(mfilename('fullpath'));
    root = fileparts(here);
    rootCopy = fullfile(root, 'PsychLVGLSetup.m');
    mCopy    = fullfile(root, 'm', 'PsychLVGLSetup.m');

    plv_assert('PsychLVGLSetup.m is at the package root', exist(rootCopy, 'file') ~= 0);
    plv_assert('PsychLVGLSetup.m is in m/', exist(mCopy, 'file') ~= 0);
    if exist(rootCopy, 'file') == 0
        return;
    end
    % Line endings can differ after a git checkout with autocrlf.
    a = strrep(fileread(rootCopy), sprintf('\r'), '');
    b = strrep(fileread(mCopy), sprintf('\r'), '');
    plv_assert('the root and m/ copies of PsychLVGLSetup.m are identical', strcmp(a, b));
    if ~strcmp(a, b)
        fprintf(2, '        copy m/PsychLVGLSetup.m over PsychLVGLSetup.m\n');
    end

    % --- remove -------------------------------------------------------------
    mdir  = fullfile(root, 'm');
    swdir = PsychLVGLSetup('distdir', 'sw');
    gldir = PsychLVGLSetup('distdir', 'gl');
    plv_assert('before remove: dist-sw/<arch> is on the path', st_index(swdir) > 0);
    plv_assert('before remove: m/ is on the path', st_index(mdir) > 0);

    % A live panel locks the MEX; remove must shut it down, not refuse.
    PsychLVGL('Init', 64, 48);
    plv_assert('Init locked the MEX', mislocked('PsychLVGL'));

    PsychLVGLSetup('remove');
    plv_assert('remove unlocked the MEX', ~mislocked('PsychLVGL'));
    plv_assert('remove took dist-sw/<arch> off the path', st_index(swdir) == 0);
    plv_assert('remove took dist/<arch> off the path', st_index(gldir) == 0);
    plv_assert('remove took m/ off the path', st_index(mdir) == 0);
    % which, not exist: exist also answers 7 for a folder of that name, and a
    % source checkout folder may be called psychlvgl.
    plv_assert('PsychLVGL is gone from the path', isempty(which('PsychLVGL')));

    % m/ is off the path now, so only the root copy can be called, from the
    % package root. The MEX is unloaded, so changing folder is safe here.
    old = cd(root);
    try
        before = path();
        PsychLVGLSetup('remove');
        plv_assert('a second remove is a no-op', strcmp(before, path()));

        PsychLVGLSetup('sw');
    catch err
        cd(old);
        rethrow(err);
    end
    cd(old);
    plv_assert('reinstall: dist-sw/<arch> is back in front of m/', ...
               st_index(swdir) > 0 && st_index(swdir) < st_index(mdir));
end

function i = st_index(d)
    parts = strsplit(path(), pathsep());
    if ispc
        hit = find(strcmpi(parts, d), 1);
    else
        hit = find(strcmp(parts, d), 1);
    end
    if isempty(hit); i = 0; else; i = hit; end
end
