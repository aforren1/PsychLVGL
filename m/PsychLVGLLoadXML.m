function [root, named] = PsychLVGLLoadXML(file, parent, opts)
% PSYCHLVGLLOADXML  Build a user interface from an LVGL editor XML file.
%   [root, named] = PsychLVGLLoadXML(file) reads a <screen> or <component>
%   file saved by the LVGL editor (LVGL Pro) and creates the widgets it
%   describes with ordinary PsychLVGL calls. It needs PsychLVGL('Init') or
%   PsychLVGLOpen first, and no OpenGL context.
%
%   [root, named] = PsychLVGLLoadXML(file, parent, opts)
%
%   parent   Where the interface goes. A <screen> file fills parent itself:
%            the view's attributes apply to it and the view's children
%            become its children. A <component> file becomes one child of
%            parent. Default: PsychLVGL('ScreenActive').
%   root     parent for a screen, the new object for a component.
%   named    Handles by the name attribute of each widget (and chart
%            series), named.label_1 for name="label_1". A name that is not
%            a valid field name is changed as ParseXML changes attribute
%            names, and a repeated name gets _2, _3, ... in document order.
%            named.subjects is the subject table of the file; see
%            PsychLVGLSubjects, which applies it each frame.
%
%   opts fields, all optional:
%   AssetDir       Folder that font and image src_path values are relative
%                  to. Default: the folder of the XML file that declares
%                  them (globals.xml for the project's assets).
%   Consts         Struct of constant values that replace the XML's
%                  <consts> of the same name, opts.Consts.accent = '0xff0000'.
%   Warn           @(id, message) called once for each distinct problem:
%                  an unknown element or attribute, an LVGL feature
%                  PsychLVGL cannot map, a reference that does not resolve,
%                  or a value that does not parse. Default: warning(id, ...).
%                  The ids are psychlvgl:XMLUnknown, psychlvgl:XMLUnsupported,
%                  psychlvgl:XMLReference and psychlvgl:XMLValue. Nothing
%                  is skipped without a call.
%   Globals        globals.xml to read first, or 'none'. Default: the first
%                  globals.xml in the file's folder or up to three folders
%                  above it, which is where the editor keeps it.
%   ComponentDirs  More folders to look in for component files. A tag such
%                  as <my_button> names my_button.xml in the file's folder,
%                  the globals folder, or one of these.
%
%   PsychLVGLXMLToM writes the same calls to an M-file instead of running
%   them. SPEC section 13 and README ("Load an XML user interface") list
%   the part of the XML format that is covered.
%
%   Example:
%     ui = PsychLVGLOpen(win, 480, 320);
%     [root, named] = PsychLVGLLoadXML('ui/main.xml');
%     PsychLVGL('LabelSetText', named.status, 'ready');
%
%   See also PSYCHLVGLXMLTOM, PSYCHLVGLSUBJECTS, PSYCHLVGLIMAGEFROMFILE.

    if nargin < 2
        parent = [];
    end
    if nargin < 3
        opts = struct();
    end
    [file, o] = plv_xml_opts(file, opts, 'PsychLVGLLoadXML');
    if isempty(parent)
        parent = PsychLVGL('ScreenActive');
    end
    if ~isnumeric(parent) || ~isscalar(parent) || ~PsychLVGL('IsValid', parent)
        error('psychlvgl:InvalidHandle', 'PsychLVGLLoadXML: parent must be a valid object handle');
    end

    assetDir = o.AssetDir;
    if isempty(assetDir)
        assetDir = fileparts(file);
    end
    em = plv_xml_emit_exec(assetDir);
    [em, root] = plv_xml_run(em, file, parent, o);
    named = em.named;
end
