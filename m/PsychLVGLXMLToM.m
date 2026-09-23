function outFile = PsychLVGLXMLToM(file, outFile, opts)
% PSYCHLVGLXMLTOM  Write an LVGL editor XML file as a MATLAB function.
%   PsychLVGLXMLToM(file, outFile) writes outFile, a function
%
%     [root, named] = name(parent, assetDir)
%
%   that makes the same PsychLVGL calls PsychLVGLLoadXML(file, parent)
%   makes, in the same order, and returns the same root and named struct.
%   Use it to read what a layout does, to edit a layout without the editor,
%   or to ship a layout with no XML file. The written function needs
%   PsychLVGL, PsychLVGLSubjects and PsychLVGLImageFromFile, nothing else.
%
%   outFile  Path of the M-file. ".m" is added when missing; its base name
%            becomes the function name and must be a valid one.
%   opts     The options of PsychLVGLLoadXML: AssetDir, Consts, Warn,
%            Globals, ComponentDirs. Warnings are reported now, while the
%            file is written, not when the function runs.
%
%   In the written function, parent defaults to PsychLVGL('ScreenActive')
%   and assetDir to the folder the assets were found in at writing time.
%   Asset paths under that folder are written relative to assetDir, so the
%   function keeps working when it moves with its assets.
%
%   The interpretation runs once here: $prop and #const references are
%   replaced by their values and components are expanded in place. Writing
%   needs no PsychLVGL('Init').
%
%   See also PSYCHLVGLLOADXML, PSYCHLVGLSUBJECTS.

    if nargin < 2 || ~ischar(outFile) || isempty(outFile)
        error('psychlvgl:Usage', 'Usage: PsychLVGLXMLToM(file, outFile [, opts])');
    end
    if nargin < 3
        opts = struct();
    end
    [file, o] = plv_xml_opts(file, opts, 'PsychLVGLXMLToM');

    [d, fname, ext] = fileparts(outFile);
    if isempty(ext)
        outFile = [outFile '.m'];
    elseif ~strcmp(ext, '.m')
        error('psychlvgl:Usage', 'PsychLVGLXMLToM: outFile must end in .m, not %s', ext);
    end
    if ~isvarname(fname)
        error('psychlvgl:Usage', ...
              'PsychLVGLXMLToM: "%s" is not a valid function name; name the file after one', fname);
    end
    if ~isempty(d) && exist(d, 'dir') ~= 7
        error('psychlvgl:Usage', 'PsychLVGLXMLToM: folder %s does not exist', d);
    end

    assetDir = o.AssetDir;
    if isempty(assetDir)
        assetDir = fileparts(file);
    end
    em = plv_xml_emit_write(assetDir);
    [em, root] = plv_xml_run(em, file, struct('code', 'parent'), o);

    pre = {
        sprintf('function [root, named] = %s(parent, assetDir)', fname)
        sprintf('%% %s  User interface written by PsychLVGLXMLToM.', upper(fname))
        sprintf('%%   [root, named] = %s(parent, assetDir) builds the interface of', fname)
        sprintf('%%   %s', file)
        '%   under parent, as PsychLVGLLoadXML(file, parent) does, and returns the'
        '%   same root and named struct. parent defaults to the active screen;'
        '%   assetDir is the folder that font and image paths are relative to.'
        '%'
        '%   Generated code: rerun PsychLVGLXMLToM after changing the XML rather'
        '%   than editing this file, or edit it and keep it as the source.'
        ''};
    code = [{
        'if nargin < 1 || isempty(parent)'
        '    parent = PsychLVGL(''ScreenActive'');'
        'end'
        'if nargin < 2 || isempty(assetDir)'
        sprintf('    assetDir = %s;', plv_xml_literal(assetDir))
        'end'
        'named = struct();'}
        reshape(em.lines(1:em.nlines), [], 1)
        {sprintf('root = %s;', plv_xml_literal(root))}];
    code = strcat({'    '}, code);
    lines = [pre; code; {'end'; ''}];
    text = sprintf('%s\n', lines{:});

    fid = fopen(outFile, 'w');
    if fid < 0
        error('psychlvgl:Usage', 'PsychLVGLXMLToM: cannot write %s', outFile);
    end
    closer = onCleanup(@() fclose(fid));
    if exist('OCTAVE_VERSION', 'builtin') ~= 0
        % Octave char is UTF-8 bytes already.
        fwrite(fid, uint8(text), 'uint8');
    else
        fwrite(fid, unicode2native(text, 'UTF-8'), 'uint8');
    end
end
