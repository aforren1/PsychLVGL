function [file, o] = plv_xml_opts(file, opts, caller)
% PLV_XML_OPTS  Checks the file and options of PsychLVGLLoadXML and
% PsychLVGLXMLToM and fills in the defaults, so the interpreter can trust
% them.
    if ~ischar(file) || isempty(file)
        error('psychlvgl:Usage', '%s: the first argument must be the path of an XML file', caller);
    end
    if exist(file, 'file') ~= 2
        error('psychlvgl:XML', '%s: %s does not exist', caller, file);
    end
    file = absolute(file);

    if nargin < 2 || isempty(opts)
        opts = struct();
    end
    if ~isstruct(opts) || ~isscalar(opts)
        error('psychlvgl:Usage', '%s: opts must be a scalar struct', caller);
    end
    known = {'AssetDir', 'Consts', 'Warn', 'Globals', 'ComponentDirs'};
    f = fieldnames(opts);
    for k = 1:numel(f)
        if ~any(strcmp(f{k}, known))
            error('psychlvgl:Usage', '%s: unknown option %s; the options are %s', ...
                  caller, f{k}, strjoin(known, ', '));
        end
    end

    o = struct('AssetDir', '', 'Consts', struct(), 'Warn', @default_warn, ...
               'Globals', '', 'ComponentDirs', {{}});
    if isfield(opts, 'AssetDir') && ~isempty(opts.AssetDir)
        if ~ischar(opts.AssetDir) || exist(opts.AssetDir, 'dir') ~= 7
            error('psychlvgl:Usage', '%s: AssetDir must name an existing folder', caller);
        end
        o.AssetDir = absolute(opts.AssetDir);
    end
    if isfield(opts, 'Consts') && ~isempty(opts.Consts)
        if ~isstruct(opts.Consts) || ~isscalar(opts.Consts)
            error('psychlvgl:Usage', '%s: Consts must be a scalar struct of constant values', caller);
        end
        o.Consts = opts.Consts;
    end
    if isfield(opts, 'Warn') && ~isempty(opts.Warn)
        if ~isa(opts.Warn, 'function_handle')
            error('psychlvgl:Usage', '%s: Warn must be a function handle, @(id, message) ...', caller);
        end
        o.Warn = opts.Warn;
    end
    if isfield(opts, 'Globals') && ~isempty(opts.Globals)
        if ~ischar(opts.Globals)
            error('psychlvgl:Usage', '%s: Globals must be a file name or ''none''', caller);
        end
        if strcmp(opts.Globals, 'none')
            o.Globals = 'none';
        else
            o.Globals = absolute(opts.Globals);
        end
    end
    if isfield(opts, 'ComponentDirs') && ~isempty(opts.ComponentDirs)
        d = opts.ComponentDirs;
        if ischar(d)
            d = {d};
        end
        if ~iscellstr(d)
            error('psychlvgl:Usage', '%s: ComponentDirs must be a folder name or a cell array of them', caller);
        end
        for k = 1:numel(d)
            d{k} = absolute(d{k});
        end
        o.ComponentDirs = d(:)';
    end
end

function default_warn(id, msg)
    warning(id, '%s', msg);
end

function p = absolute(p)
    if ~plv_xml_is_absolute(p)
        p = fullfile(pwd, p);
    end
end
