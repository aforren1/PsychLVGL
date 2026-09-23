function [em, root] = plv_xml_run(em, file, parentRef, opts)
% PLV_XML_RUN  Walk an LVGL editor XML file and drive an emitter.
%   [em, root] = plv_xml_run(em, file, parentRef, opts) is the one
%   interpreter behind PsychLVGLLoadXML (emitter plv_xml_emit_exec) and
%   PsychLVGLXMLToM (emitter plv_xml_emit_write). It never calls PsychLVGL
%   to change the user interface itself; every such call goes through the
%   emitter, so the two front ends produce the same sequence. It does call
%   PsychLVGL('ParseXML'), 'Enum', 'FontList' and PsychLVGLOp, which only read.
%
%   opts has the fields Warn, AssetDir, Consts, Globals and ComponentDirs,
%   already checked by the caller.
%
%   Tables that the walk fills as it goes (styles made on first use,
%   components parsed on first use, names handed out) are containers.Map
%   objects, which are handles, so they are shared by every copy of ctx.

    ctx = make_ctx(file, opts);

    tree = PsychLVGL('ParseXML', ctx.file);
    if numel(tree) > 1
        warn(ctx, 'psychlvgl:XMLUnknown', ...
             'only the first of %d top-level elements in %s is read', numel(tree), ctx.file);
    end
    tree = tree(1);

    em = em.subjects(em, 'create', {});
    [rn, ~] = raw_attrs(tree);
    for k = 1:numel(rn)
        % permanent="true" on a <screen> keeps it across screen loads in
        % LVGL; here the script owns every screen, so nothing maps to it.
        warn_unsupported(ctx, struct('file', ctx.file), tree.tag, sprintf('attribute "%s"', rn{k}));
    end

    gfile = find_globals(ctx, opts);
    if ~isempty(gfile) && ~same_file(gfile, ctx.file)
        g = PsychLVGL('ParseXML', gfile);
        if ~strcmp(g(1).tag, 'globals')
            warn(ctx, 'psychlvgl:XMLUnknown', ...
                 '%s has the root element <%s>, not <globals>; it is not read', gfile, g(1).tag);
        else
            gsc = ctx.globals;
            gsc.file = gfile;
            gsc.dir = fileparts(gfile);
            [em, ctx] = declare_block(em, ctx, gsc, g(1), 'globals');
        end
    end

    switch tree.tag
        case 'screen'
            [em, root] = build_screen(em, ctx, tree, parentRef);
        case 'component'
            def = component_def(ctx, tree, ctx.file, component_name(ctx.file));
            [em, root] = instantiate(em, ctx, def, {}, {}, [], ctx.globals, parentRef);
        case 'globals'
            gsc = ctx.globals;
            [em, ctx] = declare_block(em, ctx, gsc, tree, 'globals');
            root = parentRef;
        otherwise
            error('psychlvgl:XML', ...
                  '%s has the root element <%s>; expected <screen>, <component> or <globals>', ...
                  ctx.file, tree.tag);
    end

    em = em.subjects(em, 'apply', {});
end

% ======================================================================
% context and scopes

function ctx = make_ctx(file, opts)
    ctx = struct();
    ctx.file = file;
    ctx.dir = fileparts(file);
    ctx.warnFn = opts.Warn;
    ctx.warned = containers.Map('KeyType', 'char', 'ValueType', 'logical');
    ctx.assetOverride = opts.AssetDir;
    ctx.overrides = containers.Map('KeyType', 'char', 'ValueType', 'any');
    if isstruct(opts.Consts)
        f = fieldnames(opts.Consts);
        for k = 1:numel(f)
            v = opts.Consts.(f{k});
            if ~ischar(v)
                v = num2str(v);
            end
            ctx.overrides(f{k}) = v;
        end
    end
    ctx.fonts = containers.Map('KeyType', 'char', 'ValueType', 'any');
    ctx.images = containers.Map('KeyType', 'char', 'ValueType', 'any');
    ctx.imgfiles = containers.Map('KeyType', 'char', 'ValueType', 'any');
    ctx.subjects = containers.Map('KeyType', 'char', 'ValueType', 'any');
    ctx.compCache = containers.Map('KeyType', 'char', 'ValueType', 'any');
    ctx.active = containers.Map('KeyType', 'char', 'ValueType', 'logical');
    ctx.named = containers.Map('KeyType', 'char', 'ValueType', 'logical');
    ctx.enums = containers.Map('KeyType', 'char', 'ValueType', 'logical');
    ctx.ops = PsychLVGLOp();
    ctx.fontList = PsychLVGL('FontList');
    ctx.globals = new_scope(file, ctx.dir, []);
    ctx.comps = index_components(ctx, opts);
end

function sc = new_scope(file, dir, up)
    sc = struct();
    sc.file = file;
    sc.dir = dir;
    sc.consts = containers.Map('KeyType', 'char', 'ValueType', 'any');
    sc.styles = containers.Map('KeyType', 'char', 'ValueType', 'any');
    sc.props = [];
    sc.propDecl = [];
    sc.up = up;
end

function tf = same_file(a, b)
    if ispc
        tf = strcmpi(strrep(a, '/', '\'), strrep(b, '/', '\'));
    else
        tf = strcmp(a, b);
    end
end

function g = find_globals(ctx, opts)
% The editor keeps globals.xml at the project root, which is the file's own
% folder or one above it, so the search walks up a few levels.
    g = '';
    if ~isempty(opts.Globals)
        if ischar(opts.Globals) && strcmp(opts.Globals, 'none')
            return;
        end
        g = opts.Globals;
        if exist(g, 'file') ~= 2
            error('psychlvgl:XML', 'the Globals file %s does not exist', g);
        end
        return;
    end
    d = ctx.dir;
    for level = 1:4
        cand = fullfile(d, 'globals.xml');
        if exist(cand, 'file') == 2
            g = cand;
            return;
        end
        up = fileparts(d);
        if isempty(up) || strcmp(up, d)
            return;
        end
        d = up;
    end
end

function m = index_components(ctx, opts)
% Components are looked up by tag, and the tag is the file name. Listing the
% folders once keeps each lookup a map access; files are parsed on first use.
    m = containers.Map('KeyType', 'char', 'ValueType', 'char');
    dirs = [{ctx.dir}, opts.ComponentDirs(:)'];
    g = find_globals(ctx, opts);
    if ~isempty(g)
        dirs{end+1} = fileparts(g);
    end
    for k = 1:numel(dirs)
        if isempty(dirs{k}) || exist(dirs{k}, 'dir') ~= 7
            continue;
        end
        d = dir(fullfile(dirs{k}, '*.xml'));
        for j = 1:numel(d)
            [~, name] = fileparts(d(j).name);
            if any(strcmp(name, {'globals', 'project'})) || isKey(m, name)
                continue;
            end
            m(name) = fullfile(dirs{k}, d(j).name);
        end
    end
end

function name = component_name(file)
    [~, name] = fileparts(file);
end

% ======================================================================
% warnings

function warn(ctx, id, fmt, varargin)
% Each distinct message is reported once per load, so an unknown attribute
% used on fifty widgets produces one warning.
    msg = sprintf(fmt, varargin{:});
    key = [id '|' msg];
    if isKey(ctx.warned, key)
        return;
    end
    ctx.warned(key) = true;
    ctx.warnFn(id, msg);
end

function warn_unknown_attr(ctx, sc, tag, attr)
    warn(ctx, 'psychlvgl:XMLUnknown', 'unknown attribute "%s" on <%s> in %s; it is ignored', ...
         attr, tag, sc.file);
end

function warn_unsupported(ctx, sc, tag, what)
    warn(ctx, 'psychlvgl:XMLUnsupported', '%s on <%s> in %s is not supported by PsychLVGL; it is ignored', ...
         what, tag, sc.file);
end

function warn_value(ctx, sc, tag, attr, v, why)
    warn(ctx, 'psychlvgl:XMLValue', 'attribute %s="%s" on <%s> in %s: %s; it is ignored', ...
         attr, v, tag, sc.file, why);
end

% ======================================================================
% declarations: consts, styles, fonts, images, subjects

function [em, ctx] = declare_block(em, ctx, sc, node, where)
% The declaration blocks of <globals>, and the ones a <screen> or a
% <component> may carry. Fonts, images and subjects are global in LVGL
% whichever file declares them; consts and styles belong to sc.
    for k = 1:numel(node.children)
        c = node.children(k);
        switch c.tag
            case 'consts'
                declare_consts(ctx, sc, c);
            case 'styles'
                declare_styles(ctx, sc, c);
            case 'fonts'
                declare_fonts(ctx, sc, c);
            case 'images'
                declare_images(ctx, sc, c);
            case 'subjects'
                em = declare_subjects(em, ctx, sc, c);
            case 'api'
                if ~strcmp(where, 'component')
                    % Enum definitions in globals describe widgets written
                    % in C; nothing of them reaches the running interface.
                    for j = 1:numel(c.children)
                        if ~strcmp(c.children(j).tag, 'enumdef')
                            warn_unsupported(ctx, sc, 'api', sprintf('<%s>', c.children(j).tag));
                        end
                    end
                end
            case {'previews', 'preview'}
                % Editor-only: preview sizes and backgrounds.
            case {'view', 'animations', 'translations', 'gradients'}
                if strcmp(c.tag, 'view') && ~strcmp(where, 'globals')
                    continue;
                end
                warn_unsupported(ctx, sc, where, sprintf('<%s>', c.tag));
            otherwise
                warn(ctx, 'psychlvgl:XMLUnknown', 'unknown element <%s> in <%s> of %s; it is ignored', ...
                     c.tag, where, sc.file);
        end
    end
end

function declare_consts(ctx, sc, node)
    for k = 1:numel(node.children)
        c = node.children(k);
        a = c.attributes;
        if ~isfield(a, 'name') || ~isfield(a, 'value')
            warn(ctx, 'psychlvgl:XMLValue', '<%s> in <consts> of %s needs name and value; it is ignored', ...
                 c.tag, sc.file);
            continue;
        end
        sc.consts(a.name) = a.value;
    end
end

function declare_styles(ctx, sc, node)
    for k = 1:numel(node.children)
        c = node.children(k);
        if ~strcmp(c.tag, 'style')
            warn(ctx, 'psychlvgl:XMLUnknown', 'unknown element <%s> in <styles> of %s; it is ignored', ...
                 c.tag, sc.file);
            continue;
        end
        if ~isfield(c.attributes, 'name')
            warn(ctx, 'psychlvgl:XMLValue', '<style> in <styles> of %s has no name; it is ignored', sc.file);
            continue;
        end
        % Made on first use, so an unused style costs no resource handle.
        sc.styles(c.attributes.name) = struct('node', c, 'scope', sc, 'ref', []);
    end
end

function d = asset_dir(ctx, sc)
    if ~isempty(ctx.assetOverride)
        d = ctx.assetOverride;
    else
        d = sc.dir;
    end
end

function declare_fonts(ctx, sc, node)
    for k = 1:numel(node.children)
        c = node.children(k);
        a = c.attributes;
        switch c.tag
            case {'bin', 'tiny_ttf', 'freetype'}
                % All three name a TTF or OTF file and a pixel size, which
                % is what FontLoad takes; bpp, range and symbols only matter
                % to the editor's bitmap conversion.
                if ~isfield(a, 'name') || ~isfield(a, 'src_path') || ~isfield(a, 'size')
                    warn(ctx, 'psychlvgl:XMLValue', '<%s> in <fonts> of %s needs name, src_path and size', ...
                         c.tag, sc.file);
                    continue;
                end
                px = str2double(a.size);
                if isnan(px)
                    warn(ctx, 'psychlvgl:XMLValue', 'font %s in %s has size "%s"', a.name, sc.file, a.size);
                    continue;
                end
                ctx.fonts(a.name) = struct('dir', asset_dir(ctx, sc), 'src', a.src_path, ...
                                           'size', px, 'ref', []);
            otherwise
                warn_unsupported(ctx, sc, 'fonts', sprintf('<%s>', c.tag));
        end
    end
end

function declare_images(ctx, sc, node)
    for k = 1:numel(node.children)
        c = node.children(k);
        a = c.attributes;
        switch c.tag
            case {'data', 'file'}
                if ~isfield(a, 'name') || ~isfield(a, 'src_path')
                    warn(ctx, 'psychlvgl:XMLValue', '<%s> in <images> of %s needs name and src_path', ...
                         c.tag, sc.file);
                    continue;
                end
                ctx.images(a.name) = struct('dir', asset_dir(ctx, sc), 'src', a.src_path, 'ref', []);
            otherwise
                warn_unsupported(ctx, sc, 'images', sprintf('<%s>', c.tag));
        end
    end
end

function em = declare_subjects(em, ctx, sc, node)
    for k = 1:numel(node.children)
        c = node.children(k);
        a = c.attributes;
        if ~isfield(a, 'name')
            warn(ctx, 'psychlvgl:XMLValue', '<%s> in <subjects> of %s has no name', c.tag, sc.file);
            continue;
        end
        if isKey(ctx.subjects, a.name)
            continue;
        end
        switch c.tag
            case {'int', 'float'}
                v = attr_num(a, 'value', 0);
                lo = attr_num(a, 'min_value', -Inf);
                hi = attr_num(a, 'max_value', Inf);
                args = {a.name, c.tag, v, lo, hi};
            case 'string'
                v = '';
                if isfield(a, 'value'); v = a.value; end
                args = {a.name, 'string', v};
            otherwise
                warn_unsupported(ctx, sc, 'subjects', sprintf('a <%s> subject', c.tag));
                continue;
        end
        ctx.subjects(a.name) = c.tag;
        em = em.subjects(em, 'add', args);
    end
end

function v = attr_num(a, f, dflt)
    v = dflt;
    if isfield(a, f)
        x = str2double(a.(f));
        if ~isnan(x)
            v = x;
        end
    end
end

% ======================================================================
% references: $prop and #const

function [v, ok] = resolve(ctx, sc, v)
    ok = true;
    for depth = 1:8
        if isempty(v)
            return;
        end
        if v(1) == '$'
            p = v(2:end);
            if ~isempty(sc.propDecl) && isKey(sc.propDecl, p)
                % Prop values were resolved in the caller's scope already.
                ok = isKey(sc.props, p);
                if ok
                    v = sc.props(p);
                end
                return;
            end
            warn(ctx, 'psychlvgl:XMLReference', 'unknown property $%s in %s; the attribute is ignored', ...
                 p, sc.file);
            ok = false;
            return;
        elseif v(1) == '#'
            [found, val] = const_lookup(ctx, sc, v(2:end));
            if ~found
                warn(ctx, 'psychlvgl:XMLReference', 'unknown constant #%s in %s; the attribute is ignored', ...
                     v(2:end), sc.file);
                ok = false;
                return;
            end
            v = val;
        else
            return;
        end
    end
    warn(ctx, 'psychlvgl:XMLReference', 'constants in %s refer to each other in a loop', sc.file);
    ok = false;
end

function [found, val] = const_lookup(ctx, sc, name)
    found = true;
    if isKey(ctx.overrides, name)
        val = ctx.overrides(name);
        return;
    end
    s = sc;
    while ~isempty(s)
        if isKey(s.consts, name)
            val = s.consts(name);
            return;
        end
        s = s.up;
    end
    if isKey(ctx.globals.consts, name)
        val = ctx.globals.consts(name);
        return;
    end
    found = false;
    val = '';
end

function [names, vals] = raw_attrs(node)
    vals = struct2cell(node.attributes)';
    if isempty(node.attr_names)
        names = fieldnames(node.attributes)';
    else
        names = node.attr_names;
    end
end

function [names, vals] = gather(ctx, sc, node, skip)
% The attributes of node with $ and # resolved in sc. An attribute whose
% reference does not resolve is dropped, as LVGL drops it.
    [names, vals] = raw_attrs(node);
    keep = true(1, numel(names));
    for k = 1:numel(names)
        if any(strcmp(names{k}, skip))
            keep(k) = false;
            continue;
        end
        [vals{k}, keep(k)] = resolve(ctx, sc, vals{k});
    end
    names = names(keep);
    vals = vals(keep);
end

function [names, vals] = merge(names, vals, n2, v2)
% Later attributes win, as an instance's attributes override its view's.
    for k = 1:numel(n2)
        i = find(strcmp(names, n2{k}), 1);
        if isempty(i)
            names{end+1} = n2{k}; %#ok<AGROW>
            vals{end+1} = v2{k}; %#ok<AGROW>
        else
            vals{i} = v2{k};
        end
    end
end

function [v, has] = attr(names, vals, key)
    i = find(strcmp(names, key), 1);
    has = ~isempty(i);
    if has
        v = vals{i};
    else
        v = '';
    end
end

% ======================================================================
% screens and components

function [em, root] = build_screen(em, ctx, tree, parentRef)
    sc = new_scope(ctx.file, ctx.dir, ctx.globals);
    view = [];
    for k = 1:numel(tree.children)
        c = tree.children(k);
        if strcmp(c.tag, 'view')
            view = c;
        else
            [em, ctx] = declare_block(em, ctx, sc, struct('children', c), 'screen');
        end
    end
    root = parentRef;
    if isempty(view)
        return;
    end
    [names, vals] = gather(ctx, sc, view, {});
    if any(strcmp(names, 'extends'))
        warn_unsupported(ctx, sc, 'view', 'extends on a <screen> view');
        [names, vals] = drop(names, vals, 'extends');
    end
    em = em.comment(em, sprintf('<screen> %s', ctx.file));
    [em, info] = apply_attrs(em, ctx, sc, 'obj', root, names, vals, 'view');
    em = build_children(em, ctx, sc, view.children, root, 'obj', info);
end

function [names, vals] = drop(names, vals, key)
    keep = ~strcmp(names, key);
    names = names(keep);
    vals = vals(keep);
end

function def = component_def(ctx, tree, file, name)
    def = struct();
    def.name = name;
    def.file = file;
    def.scope = new_scope(file, fileparts(file), ctx.globals);
    def.tree = tree;
    def.view = [];
    def.extends = 'lv_obj';
    def.propNames = {};
    def.propDefaults = {};
    def.propHasDefault = false(1, 0);
end

function [def, ok] = get_component(ctx, name)
    ok = true;
    if isKey(ctx.compCache, name)
        def = ctx.compCache(name);
        return;
    end
    def = [];
    ok = false;
    if ~isKey(ctx.comps, name)
        return;
    end
    path = ctx.comps(name);
    tree = PsychLVGL('ParseXML', path);
    if ~strcmp(tree(1).tag, 'component')
        return;
    end
    def = component_def(ctx, tree(1), path, name);
    ok = true;
    ctx.compCache(name) = def;
end

function [em, def] = prepare_component(em, ctx, def)
% The declarations of a component are read once, on its first instance, so
% its styles are shared by every instance as LVGL shares them.
    if isfield(def, 'prepared')
        return;
    end
    sc = def.scope;
    for k = 1:numel(def.tree.children)
        c = def.tree.children(k);
        switch c.tag
            case 'view'
                def.view = c;
                if isfield(c.attributes, 'extends')
                    def.extends = c.attributes.extends;
                end
            case 'api'
                for j = 1:numel(c.children)
                    p = c.children(j);
                    if strcmp(p.tag, 'prop') && isfield(p.attributes, 'name')
                        def.propNames{end+1} = p.attributes.name;
                        def.propHasDefault(end+1) = isfield(p.attributes, 'default');
                        if isfield(p.attributes, 'default')
                            def.propDefaults{end+1} = p.attributes.default;
                        else
                            def.propDefaults{end+1} = '';
                        end
                    else
                        warn_unsupported(ctx, sc, 'api', sprintf('<%s> in a component', p.tag));
                    end
                end
            otherwise
                [em, ctx] = declare_block(em, ctx, sc, struct('children', c), 'component');
        end
    end
    def.prepared = true;
    ctx.compCache(def.name) = def;
end

function [em, ref, kind, info] = instantiate(em, ctx, def, instNames, instVals, instChildren, callerScope, parentRef)
    ref = [];
    kind = 'obj';
    info = struct();
    if isKey(ctx.active, def.name)
        warn(ctx, 'psychlvgl:XMLValue', 'component %s contains itself; the inner instance is skipped', def.name);
        return;
    end
    [em, def] = prepare_component(em, ctx, def);
    if isempty(def.view)
        warn(ctx, 'psychlvgl:XMLValue', 'component %s in %s has no <view>', def.name, def.file);
        return;
    end
    ctx.active(def.name) = true;
    cleanup = onCleanup(@() remove(ctx.active, def.name)); %#ok<NASGU>

    sc = def.scope;
    sc.props = containers.Map('KeyType', 'char', 'ValueType', 'any');
    sc.propDecl = containers.Map('KeyType', 'char', 'ValueType', 'logical');
    isProp = false(1, numel(instNames));
    for k = 1:numel(def.propNames)
        p = def.propNames{k};
        sc.propDecl(p) = true;
        i = find(strcmp(instNames, p), 1);
        if ~isempty(i)
            sc.props(p) = instVals{i};
            isProp(i) = true;
        elseif def.propHasDefault(k)
            dsc = def.scope;       % a default is resolved without props
            [v, ok] = resolve(ctx, dsc, def.propDefaults{k});
            if ok
                sc.props(p) = v;
            end
        end
    end

    em = em.comment(em, sprintf('<%s> from %s', def.name, def.file));
    [vn, vv] = gather(ctx, sc, def.view, {'extends'});
    [mn, mv] = merge(vn, vv, instNames(~isProp), instVals(~isProp));

    base = def.extends;
    wk = widget_kind(base);
    if ~isempty(wk)
        [em, ref] = create_widget(em, wk, parentRef, mn, mv);
        kind = wk.kind;
        [em, info] = apply_attrs(em, ctx, sc, kind, ref, mn, mv, def.name);
    else
        [bdef, ok] = get_component(ctx, base);
        if ~ok
            warn(ctx, 'psychlvgl:XMLUnknown', 'component %s extends "%s", which is not a known widget or component', ...
                 def.name, base);
            return;
        end
        [em, ref, kind, info] = instantiate(em, ctx, bdef, mn, mv, {}, sc, parentRef);
        if isempty(ref)
            return;
        end
    end
    em = build_children(em, ctx, sc, def.view.children, ref, kind, info);
    em = build_children(em, ctx, callerScope, instChildren, ref, kind, info);
end

% ======================================================================
% widgets

function wk = widget_kind(tag)
% The widgets of the allowlist, by XML tag.
    persistent table
    if isempty(table)
        table = struct( ...
            'lv_obj',      {{'obj', 'ObjCreate'}}, ...
            'lv_label',    {{'label', 'LabelCreate'}}, ...
            'lv_button',   {{'button', 'ButtonCreate'}}, ...
            'lv_slider',   {{'slider', 'SliderCreate'}}, ...
            'lv_switch',   {{'switch', 'SwitchCreate'}}, ...
            'lv_checkbox', {{'checkbox', 'CheckboxCreate'}}, ...
            'lv_bar',      {{'bar', 'BarCreate'}}, ...
            'lv_arc',      {{'arc', 'ArcCreate'}}, ...
            'lv_dropdown', {{'dropdown', 'DropdownCreate'}}, ...
            'lv_roller',   {{'roller', 'RollerCreate'}}, ...
            'lv_textarea', {{'textarea', 'TextareaCreate'}}, ...
            'lv_spinbox',  {{'spinbox', 'SpinboxCreate'}}, ...
            'lv_table',    {{'table', 'TableCreate'}}, ...
            'lv_chart',    {{'chart', 'ChartCreate'}}, ...
            'lv_image',    {{'image', 'ImageCreate'}});
    end
    wk = [];
    if isvarname(tag) && isfield(table, tag)
        e = table.(tag);
        wk = struct('kind', e{1}, 'create', e{2}, 'tag', tag);
    end
end

function [em, ref] = create_widget(em, wk, parentRef, names, vals)
    [hint, has] = attr(names, vals, 'name');
    if ~has
        hint = wk.kind;
    end
    [em, ref] = em.call(em, 'PsychLVGL', {wk.create, parentRef}, hint);
end

function em = build_children(em, ctx, sc, children, parentRef, parentKind, info)
    for k = 1:numel(children)
        c = children(k);
        wk = widget_kind(c.tag);
        if ~isempty(wk)
            [names, vals] = gather(ctx, sc, c, {});
            [em, ref] = create_widget(em, wk, parentRef, names, vals);
            [em, cinfo] = apply_attrs(em, ctx, sc, wk.kind, ref, names, vals, c.tag);
            em = build_children(em, ctx, sc, c.children, ref, wk.kind, cinfo);
            continue;
        end
        [em, handled] = directive(em, ctx, sc, c, parentRef, parentKind, info);
        if handled
            continue;
        end
        [def, ok] = get_component(ctx, c.tag);
        if ok
            [names, vals] = gather(ctx, sc, c, {});
            em = instantiate(em, ctx, def, names, vals, c.children, sc, parentRef);
            continue;
        end
        warn(ctx, 'psychlvgl:XMLUnknown', ...
             'unknown element <%s> in %s: not a widget PsychLVGL binds, nor a component in %s; it is ignored', ...
             c.tag, sc.file, strjoin(unique(component_dirs(ctx)), ', '));
    end
end

function d = component_dirs(ctx)
    k = values(ctx.comps);
    d = {ctx.dir};
    for i = 1:numel(k)
        d{end+1} = fileparts(k{i}); %#ok<AGROW>
    end
end

% ======================================================================
% attributes

function [em, info] = apply_attrs(em, ctx, sc, kind, ref, names, vals, tag)
    info = struct();
    spec = kind_attrs(kind);
    isSpec = false(1, numel(names));
    for k = 1:numel(names)
        isSpec(k) = any(strcmp(names{k}, spec));
    end
    [em, info] = apply_kind(em, ctx, sc, kind, ref, names(isSpec), vals(isSpec), tag);

    flags = {'hidden', 'clickable', 'click_focusable', 'checkable', 'scrollable', ...
             'scroll_elastic', 'scroll_momentum', 'scroll_one', 'scroll_chain_hor', ...
             'scroll_chain_ver', 'scroll_chain', 'scroll_on_focus', 'scroll_with_arrow', ...
             'snappable', 'press_lock', 'event_bubble', 'event_trickle', 'state_trickle', ...
             'gesture_bubble', 'adv_hittest', 'ignore_layout', 'floating', ...
             'send_draw_task_events', 'overflow_visible', 'flex_in_new_track', 'radio_button'};
    states = {'checked', 'focused', 'focus_key', 'edited', 'hovered', 'pressed', 'scrolled', 'disabled'};

    for k = find(~isSpec)
        n = names{k};
        v = vals{k};
        switch n
            case 'name'
                em = register_name(em, ctx, ref, v, true);
            case {'x', 'y', 'width', 'height'}
                [x, ok] = to_int(ctx, sc, tag, n, v);
                if ok
                    setter = struct('x', 'ObjSetX', 'y', 'ObjSetY', 'width', 'ObjSetWidth', ...
                                    'height', 'ObjSetHeight');
                    em = em.call(em, 'PsychLVGL', {setter.(n), ref, x}, '');
                end
            case 'align'
                em = enum_call(em, ctx, sc, tag, n, v, 'LV_ALIGN_', 'ObjSetStyleAlign', ref);
            case 'flex_flow'
                em = enum_call(em, ctx, sc, tag, n, v, 'LV_FLEX_FLOW_', 'ObjSetFlexFlow', ref);
            case 'scrollbar_mode'
                em = enum_call(em, ctx, sc, tag, n, v, 'LV_SCROLLBAR_MODE_', 'ObjSetScrollbarMode', ref);
            case 'scroll_snap_x'
                em = enum_call(em, ctx, sc, tag, n, v, 'LV_SCROLL_SNAP_', 'ObjSetScrollSnapX', ref);
            case 'scroll_snap_y'
                em = enum_call(em, ctx, sc, tag, n, v, 'LV_SCROLL_SNAP_', 'ObjSetScrollSnapY', ref);
            case 'scroll_dir'
                em = enum_call(em, ctx, sc, tag, n, v, 'LV_DIR_', 'ObjSetScrollDir', ref);
            case {'flex_grow', 'ext_click_area'}
                [x, ok] = to_int(ctx, sc, tag, n, v);
                if ok
                    setter = struct('flex_grow', 'ObjSetFlexGrow', 'ext_click_area', 'ObjSetExtClickArea');
                    em = em.call(em, 'PsychLVGL', {setter.(n), ref, x}, '');
                end
            case flags
                % lv_obj_set_<flag>: LVGL 9.6 logs a deprecation warning for
                % every lv_obj_add_flag and lv_obj_remove_flag call.
                em = em.call(em, 'PsychLVGL', {['ObjSet' camel(n)], ref, to_bool(v)}, '');
            case states
                e = enum_name(ctx, sc, tag, n, n, 'LV_STATE_');
                if isempty(e)
                    continue;
                elseif to_bool(v)
                    em = em.call(em, 'PsychLVGL', {'ObjAddState', ref, e}, '');
                else
                    em = em.call(em, 'PsychLVGL', {'ObjRemoveState', ref, e}, '');
                end
            case 'styles'
                em = apply_styles_attr(em, ctx, sc, ref, v, tag);
            case 'bind_checked'
                if subject_ok(ctx, sc, tag, v)
                    em = em.subjects(em, 'bind', {'checked', ref, v});
                end
            otherwise
                if strncmp(n, 'style_', 6)
                    em = apply_local_style(em, ctx, sc, ref, n, v, tag);
                elseif strncmp(n, 'bind_', 5)
                    warn_unsupported(ctx, sc, tag, sprintf('attribute "%s"', n));
                else
                    warn_unknown_attr(ctx, sc, tag, n);
                end
        end
    end
end

function spec = kind_attrs(kind)
% Attributes that only the widget's own setters understand, applied as a
% group in an order that LVGL needs (a range before a value, options
% before a selection).
    switch kind
        case 'label'
            spec = {'text', 'long_mode', 'recolor', 'text_selection_start', 'text_selection_end', ...
                    'translation_tag', 'bind_text', 'bind_text-fmt'};
        case 'checkbox'
            spec = {'text'};
        case 'slider'
            spec = {'min_value', 'max_value', 'value', 'value-anim', 'start_value', ...
                    'start_value-anim', 'mode', 'orientation', 'bind_value'};
        case 'bar'
            spec = {'min_value', 'max_value', 'value', 'value-animated', 'start_value', ...
                    'start_value-animated', 'mode', 'orientation', 'bind_value'};
        case 'arc'
            spec = {'min_value', 'max_value', 'value', 'start_angle', 'end_angle', ...
                    'bg_start_angle', 'bg_end_angle', 'rotation', 'mode', 'change_rate', 'bind_value'};
        case 'switch'
            spec = {'orientation'};
        case 'dropdown'
            spec = {'options', 'selected', 'text', 'dir', 'symbol', 'bind_value'};
        case 'roller'
            spec = {'options', 'options-mode', 'selected', 'selected-animated', ...
                    'visible_row_count', 'bind_value'};
        case 'textarea'
            spec = {'text', 'placeholder_text', 'one_line', 'password_mode', 'password_show_time', ...
                    'max_length', 'accepted_chars', 'cursor_pos', 'text_selection'};
        case 'spinbox'
            spec = {'value', 'rollover', 'digit_count', 'dec_point_pos', 'min_value', 'max_value', ...
                    'step', 'bind_value'};
        case 'table'
            spec = {'row_count', 'column_count'};
        case 'chart'
            spec = {'type', 'point_count', 'update_mode', 'hor_div_line_count', 'ver_div_line_count'};
        case 'image'
            spec = {'src', 'inner_align', 'rotation', 'scale', 'scale_x', 'scale_y', 'pivot_x', ...
                    'pivot_y', 'offset_x', 'offset_y', 'antialias', 'bind_src'};
        otherwise
            spec = {};
    end
end

function [em, info] = apply_kind(em, ctx, sc, kind, ref, names, vals, tag)
    info = struct();
    if isempty(names) && ~strcmp(kind, 'chart')
        return;
    end
    A = struct('names', {names}, 'vals', {vals});
    switch kind
        case 'label'
            em = set_str(em, A, 'text', 'LabelSetText', ref);
            em = set_enum(em, ctx, sc, tag, A, 'long_mode', 'LV_LABEL_LONG_MODE_', 'LabelSetLongMode', ref);
            em = set_bool(em, A, 'recolor', 'LabelSetRecolor', ref);
            em = set_int(em, ctx, sc, tag, A, 'text_selection_start', 'LabelSetTextSelectionStart', ref);
            em = set_int(em, ctx, sc, tag, A, 'text_selection_end', 'LabelSetTextSelectionEnd', ref);
            if has(A, 'translation_tag')
                warn_unsupported(ctx, sc, tag, 'attribute "translation_tag"');
            end
            [s, hs] = get(A, 'bind_text');
            if hs && subject_ok(ctx, sc, tag, s)
                fmt = get(A, 'bind_text-fmt');
                em = em.subjects(em, 'bind', {'text', ref, s, fmt});
            elseif ~hs && has(A, 'bind_text-fmt')
                warn_value(ctx, sc, tag, 'bind_text-fmt', get(A, 'bind_text-fmt'), 'it needs bind_text');
            end
        case 'checkbox'
            em = set_str(em, A, 'text', 'CheckboxSetText', ref);
        case {'slider', 'bar'}
            P = struct('slider', 'Slider', 'bar', 'Bar');
            P = P.(kind);
            anim = struct('slider', '-anim', 'bar', '-animated');
            anim = anim.(kind);
            em = set_enum(em, ctx, sc, tag, A, 'mode', ['LV_' upper(kind) '_MODE_'], [P 'SetMode'], ref);
            em = set_enum(em, ctx, sc, tag, A, 'orientation', ['LV_' upper(kind) '_ORIENTATION_'], ...
                          [P 'SetOrientation'], ref);
            em = set_range(em, ctx, sc, tag, A, [P 'SetRange'], ref, 0, 100);
            em = set_value_anim(em, ctx, sc, tag, A, 'value', ['value' anim], [P 'SetValue'], ref);
            em = set_value_anim(em, ctx, sc, tag, A, 'start_value', ['start_value' anim], ...
                                [P 'SetStartValue'], ref);
            em = bind_value(em, ctx, sc, tag, A, kind, ref);
        case 'arc'
            em = set_enum(em, ctx, sc, tag, A, 'mode', 'LV_ARC_MODE_', 'ArcSetMode', ref);
            em = set_range(em, ctx, sc, tag, A, 'ArcSetRange', ref, 0, 100);
            em = set_int(em, ctx, sc, tag, A, 'bg_start_angle', 'ArcSetBgStartAngle', ref);
            em = set_int(em, ctx, sc, tag, A, 'bg_end_angle', 'ArcSetBgEndAngle', ref);
            em = set_int(em, ctx, sc, tag, A, 'start_angle', 'ArcSetStartAngle', ref);
            em = set_int(em, ctx, sc, tag, A, 'end_angle', 'ArcSetEndAngle', ref);
            em = set_int(em, ctx, sc, tag, A, 'rotation', 'ArcSetRotation', ref);
            em = set_int(em, ctx, sc, tag, A, 'change_rate', 'ArcSetChangeRate', ref);
            em = set_int(em, ctx, sc, tag, A, 'value', 'ArcSetValue', ref);
            em = bind_value(em, ctx, sc, tag, A, kind, ref);
        case 'switch'
            em = set_enum(em, ctx, sc, tag, A, 'orientation', 'LV_SWITCH_ORIENTATION_', ...
                          'SwitchSetOrientation', ref);
        case 'dropdown'
            em = set_str(em, A, 'options', 'DropdownSetOptions', ref);
            em = set_int(em, ctx, sc, tag, A, 'selected', 'DropdownSetSelected', ref);
            em = set_str(em, A, 'text', 'DropdownSetText', ref);
            em = set_enum(em, ctx, sc, tag, A, 'dir', 'LV_DIR_', 'DropdownSetDir', ref);
            if has(A, 'symbol')
                warn_unsupported(ctx, sc, tag, 'attribute "symbol"');
            end
            em = bind_value(em, ctx, sc, tag, A, kind, ref);
        case 'roller'
            [o, ho] = get(A, 'options');
            if ho
                [m, hm] = get(A, 'options-mode');
                if ~hm
                    m = 'normal';
                end
                e = enum_name(ctx, sc, tag, 'options-mode', m, 'LV_ROLLER_MODE_');
                if ~isempty(e)
                    em = em.call(em, 'PsychLVGL', {'RollerSetOptions', ref, o, e}, '');
                end
            end
            em = set_value_anim(em, ctx, sc, tag, A, 'selected', 'selected-animated', 'RollerSetSelected', ref);
            em = set_int(em, ctx, sc, tag, A, 'visible_row_count', 'RollerSetVisibleRowCount', ref);
            em = bind_value(em, ctx, sc, tag, A, kind, ref);
        case 'textarea'
            em = set_bool(em, A, 'one_line', 'TextareaSetOneLine', ref);
            em = set_bool(em, A, 'password_mode', 'TextareaSetPasswordMode', ref);
            em = set_int(em, ctx, sc, tag, A, 'password_show_time', 'TextareaSetPasswordShowTime', ref);
            em = set_int(em, ctx, sc, tag, A, 'max_length', 'TextareaSetMaxLength', ref);
            em = set_str(em, A, 'accepted_chars', 'TextareaSetAcceptedChars', ref);
            em = set_str(em, A, 'placeholder_text', 'TextareaSetPlaceholderText', ref);
            em = set_str(em, A, 'text', 'TextareaSetText', ref);
            em = set_int(em, ctx, sc, tag, A, 'cursor_pos', 'TextareaSetCursorPos', ref);
            if has(A, 'text_selection')
                warn_unsupported(ctx, sc, tag, 'attribute "text_selection"');
            end
        case 'spinbox'
            em = set_int(em, ctx, sc, tag, A, 'digit_count', 'SpinboxSetDigitCount', ref);
            em = set_int(em, ctx, sc, tag, A, 'dec_point_pos', 'SpinboxSetDecPointPos', ref);
            em = set_range(em, ctx, sc, tag, A, 'SpinboxSetRange', ref, -99999, 99999);
            em = set_int(em, ctx, sc, tag, A, 'step', 'SpinboxSetStep', ref);
            em = set_bool(em, A, 'rollover', 'SpinboxSetRollover', ref);
            em = set_int(em, ctx, sc, tag, A, 'value', 'SpinboxSetValue', ref);
            em = bind_value(em, ctx, sc, tag, A, kind, ref);
        case 'table'
            em = set_int(em, ctx, sc, tag, A, 'row_count', 'TableSetRowCount', ref);
            em = set_int(em, ctx, sc, tag, A, 'column_count', 'TableSetColumnCount', ref);
        case 'chart'
            em = set_enum(em, ctx, sc, tag, A, 'type', 'LV_CHART_TYPE_', 'ChartSetType', ref);
            em = set_int(em, ctx, sc, tag, A, 'point_count', 'ChartSetPointCount', ref);
            em = set_enum(em, ctx, sc, tag, A, 'update_mode', 'LV_CHART_UPDATE_MODE_', ...
                          'ChartSetUpdateMode', ref);
            em = set_int(em, ctx, sc, tag, A, 'hor_div_line_count', 'ChartSetHorDivLineCount', ref);
            em = set_int(em, ctx, sc, tag, A, 'ver_div_line_count', 'ChartSetVerDivLineCount', ref);
            % ChartSetValues refuses more values than points; LVGL's
            % default is 10.
            info.pointCount = 10;
            [p, hp] = get(A, 'point_count');
            if hp && ~isnan(str2double(p))
                info.pointCount = str2double(p);
            end
        case 'image'
            [s, hs] = get(A, 'src');
            if hs
                [em, img, ok] = image_ref(em, ctx, sc, tag, s);
                if ok
                    em = em.call(em, 'PsychLVGL', {'ImageSetSrc', ref, img}, '');
                end
            end
            em = set_enum(em, ctx, sc, tag, A, 'inner_align', 'LV_IMAGE_ALIGN_', 'ImageSetInnerAlign', ref);
            em = set_int(em, ctx, sc, tag, A, 'rotation', 'ImageSetRotation', ref);
            em = set_int(em, ctx, sc, tag, A, 'scale', 'ImageSetScale', ref);
            em = set_int(em, ctx, sc, tag, A, 'scale_x', 'ImageSetScaleX', ref);
            em = set_int(em, ctx, sc, tag, A, 'scale_y', 'ImageSetScaleY', ref);
            em = set_int(em, ctx, sc, tag, A, 'pivot_x', 'ImageSetPivotX', ref);
            em = set_int(em, ctx, sc, tag, A, 'pivot_y', 'ImageSetPivotY', ref);
            em = set_int(em, ctx, sc, tag, A, 'offset_x', 'ImageSetOffsetX', ref);
            em = set_int(em, ctx, sc, tag, A, 'offset_y', 'ImageSetOffsetY', ref);
            em = set_bool(em, A, 'antialias', 'ImageSetAntialias', ref);
            if has(A, 'bind_src')
                warn_unsupported(ctx, sc, tag, 'attribute "bind_src"');
            end
    end
end

function [v, h] = get(A, key)
    [v, h] = attr(A.names, A.vals, key);
end

function h = has(A, key)
    h = any(strcmp(A.names, key));
end

function em = set_str(em, A, key, cmd, ref)
    [v, h] = get(A, key);
    if h
        em = em.call(em, 'PsychLVGL', {cmd, ref, v}, '');
    end
end

function em = set_bool(em, A, key, cmd, ref)
    [v, h] = get(A, key);
    if h
        em = em.call(em, 'PsychLVGL', {cmd, ref, to_bool(v)}, '');
    end
end

function em = set_int(em, ctx, sc, tag, A, key, cmd, ref)
    [v, h] = get(A, key);
    if h
        [x, ok] = to_int(ctx, sc, tag, key, v);
        if ok
            em = em.call(em, 'PsychLVGL', {cmd, ref, x}, '');
        end
    end
end

function em = set_enum(em, ctx, sc, tag, A, key, prefix, cmd, ref)
    [v, h] = get(A, key);
    if h
        em = enum_call(em, ctx, sc, tag, key, v, prefix, cmd, ref);
    end
end

function em = enum_call(em, ctx, sc, tag, key, v, prefix, cmd, ref)
    e = enum_name(ctx, sc, tag, key, v, prefix);
    if ~isempty(e)
        em = em.call(em, 'PsychLVGL', {cmd, ref, e}, '');
    end
end

function em = set_range(em, ctx, sc, tag, A, cmd, ref, lo, hi)
% LVGL sets both ends in one call. The XML may give one, and the other is
% then the widget's default, which is what it still is at creation time.
    [a, ha] = get(A, 'min_value');
    [b, hb] = get(A, 'max_value');
    if ~ha && ~hb
        return;
    end
    ok = true;
    if ha
        [lo, ok] = to_int(ctx, sc, tag, 'min_value', a);
    end
    if hb && ok
        [hi, ok] = to_int(ctx, sc, tag, 'max_value', b);
    end
    if ok
        em = em.call(em, 'PsychLVGL', {cmd, ref, lo, hi}, '');
    end
end

function em = set_value_anim(em, ctx, sc, tag, A, key, animKey, cmd, ref)
    [v, h] = get(A, key);
    if ~h
        return;
    end
    [x, ok] = to_int(ctx, sc, tag, key, v);
    if ok
        [an, ha] = get(A, animKey);
        em = em.call(em, 'PsychLVGL', {cmd, ref, x, ha && to_bool(an)}, '');
    end
end

function em = bind_value(em, ctx, sc, tag, A, kind, ref)
    [s, h] = get(A, 'bind_value');
    if h && subject_ok(ctx, sc, tag, s)
        em = em.subjects(em, 'bind', {'value', ref, s, kind});
    end
end

function ok = subject_ok(ctx, sc, tag, name)
    ok = isKey(ctx.subjects, name);
    if ~ok
        warn(ctx, 'psychlvgl:XMLReference', 'unknown subject "%s" on <%s> in %s; the binding is ignored', ...
             name, tag, sc.file);
    end
end

function em = register_name(em, ctx, ref, name, isObj)
% Names become field names of the returned struct. Two widgets can carry
% one name (in different component instances, for example); the later ones
% get a numeric suffix, in document order, in both front ends alike.
    key = regexprep(name, '[^A-Za-z0-9_]', '_');
    if isempty(key) || ~isletter(key(1)) || iskeyword(key)
        key = ['x' key];
    end
    key = key(1:min(end, 60));
    base = key;
    n = 1;
    while isKey(ctx.named, key) || strcmp(key, 'subjects')
        n = n + 1;
        key = sprintf('%s_%d', base, n);
    end
    ctx.named(key) = true;
    em = em.setnamed(em, key, ref);
    if isObj
        em = em.call(em, 'PsychLVGL', {'ObjSetName', ref, name}, '');
    end
end

% ======================================================================
% values

function [x, ok] = to_int(ctx, sc, tag, key, v)
% A number in pixels, "Npx", "N%" (LVGL's lv_pct) or "content"
% (LV_SIZE_CONTENT). LVGL's own parser truncates like atoi.
    ok = true;
    s = strtrim(v);
    if strcmp(s, 'content')
        x = 2^30 - 1;
        return;
    end
    pct = ~isempty(s) && s(end) == '%';
    if pct
        s = s(1:end-1);
    elseif numel(s) > 2 && strcmp(s(end-1:end), 'px')
        s = s(1:end-2);
    end
    x = str2double(s);
    if isnan(x) || ~isreal(x)
        warn_value(ctx, sc, tag, key, v, 'not a number');
        ok = false;
        return;
    end
    x = fix(x);
    if pct
        posMax = 2^28 - 1;
        if x < 0
            x = 2^29 + posMax - max(x, -posMax);
        else
            x = 2^29 + min(x, posMax);
        end
    end
end

function tf = to_bool(v)
    tf = ~any(strcmpi(strtrim(v), {'false', '0', 'no', 'off'}));
end

function e = enum_name(ctx, sc, tag, key, v, prefix)
% One enum name, or several joined with |, each checked against the
% generated table so a typo warns instead of aborting the load.
    parts = regexp(v, '\|', 'split');
    for k = 1:numel(parts)
        p = strtrim(parts{k});
        name = [prefix upper(p)];
        if ~enum_exists(ctx, name)
            warn_value(ctx, sc, tag, key, v, sprintf('%s is not an LVGL constant', name));
            e = '';
            return;
        end
        parts{k} = name;
    end
    e = strjoin(parts, '|');
end

function tf = enum_exists(ctx, name)
    if isKey(ctx.enums, name)
        tf = ctx.enums(name);
        return;
    end
    try
        PsychLVGL('Enum', name);
        tf = true;
    catch
        tf = false;
    end
    ctx.enums(name) = tf;
end

function [c, ok] = to_color(v)
% 0xRRGGBB, #RRGGBB left over from an unresolved constant is not accepted,
% and a three digit form doubles each digit, as lv_color_hex3 does.
    ok = false;
    c = [];
    s = strtrim(v);
    if numel(s) > 2 && strcmpi(s(1:2), '0x')
        s = s(3:end);
    end
    if isempty(regexp(s, '^[0-9a-fA-F]{1,6}$', 'once'))
        return;
    end
    if numel(s) <= 3
        s = [repmat('0', 1, 3 - numel(s)) s];
        s = s([1 1 2 2 3 3]);
    else
        s = [repmat('0', 1, 6 - numel(s)) s];
    end
    c = [hex2dec(s(1:2)) hex2dec(s(3:4)) hex2dec(s(5:6))];
    ok = true;
end

function [o, ok] = to_opa(v)
    s = strtrim(v);
    ok = true;
    if ~isempty(s) && s(end) == '%'
        o = str2double(s(1:end-1));
        o = fix(o * 255 / 100);
    else
        o = str2double(s);
    end
    if isnan(o)
        ok = false;
        return;
    end
    o = min(max(fix(o), 0), 255);
end

% ======================================================================
% styles

function k = style_kind(prop)
    persistent enums
    if isempty(enums)
        enums = struct('align', 'LV_ALIGN_', 'base_dir', 'LV_BASE_DIR_', ...
            'bg_grad_dir', 'LV_GRAD_DIR_', 'blend_mode', 'LV_BLEND_MODE_', ...
            'blur_quality', 'LV_BLUR_QUALITY_', 'drop_shadow_quality', 'LV_BLUR_QUALITY_', ...
            'border_side', 'LV_BORDER_SIDE_', 'flex_flow', 'LV_FLEX_FLOW_', ...
            'flex_main_place', 'LV_FLEX_ALIGN_', 'flex_cross_place', 'LV_FLEX_ALIGN_', ...
            'flex_track_place', 'LV_FLEX_ALIGN_', 'grid_cell_x_align', 'LV_GRID_ALIGN_', ...
            'grid_cell_y_align', 'LV_GRID_ALIGN_', 'grid_column_align', 'LV_GRID_ALIGN_', ...
            'grid_row_align', 'LV_GRID_ALIGN_', 'text_align', 'LV_TEXT_ALIGN_', ...
            'text_decor', 'LV_TEXT_DECOR_', 'text_leading_trim', 'LV_TEXT_LEADING_TRIM_');
    end
    k = struct('type', 'int', 'prefix', '');
    if isvarname(prop) && isfield(enums, prop)
        k.type = 'enum';
        k.prefix = enums.(prop);
    elseif strcmp(prop, 'layout')
        k.type = 'layout';
    elseif strcmp(prop, 'text_font')
        k.type = 'font';
    elseif strcmp(prop, 'recolor') || (numel(prop) > 6 && strcmp(prop(end-5:end), '_color'))
        k.type = 'color';
    elseif any(strcmp(prop, {'opa', 'opa_layered'})) || (numel(prop) > 4 && strcmp(prop(end-3:end), '_opa'))
        k.type = 'opa';
    elseif any(strcmp(prop, {'arc_rounded', 'bg_image_tiled', 'blur_backdrop', 'border_post', ...
                             'clip_corner', 'line_rounded'}))
        k.type = 'bool';
    elseif any(strcmp(prop, {'bg_grad', 'bg_image_src', 'arc_image_src', 'bitmap_mask_src', ...
                             'color_filter_dsc', 'grid_column_dsc_array', 'grid_row_dsc_array', ...
                             'image_colorkey', 'transition', 'anim'}))
        k.type = 'unsupported';
    end
end

function c = camel(prop)
    parts = regexp(prop, '_', 'split');
    for k = 1:numel(parts)
        if ~isempty(parts{k})
            parts{k}(1) = upper(parts{k}(1));
        end
    end
    c = [parts{:}];
end

function [em, val, ok] = style_value(em, ctx, sc, prop, v, tag, attrName)
    val = [];
    ok = true;
    k = style_kind(prop);
    switch k.type
        case 'color'
            [val, ok] = to_color(v);
            if ~ok
                warn_value(ctx, sc, tag, attrName, v, 'not a color of the form 0xRRGGBB');
            end
        case 'opa'
            [val, ok] = to_opa(v);
            if ~ok
                warn_value(ctx, sc, tag, attrName, v, 'not an opacity, 0 to 255 or a percentage');
            end
        case 'bool'
            val = to_bool(v);
        case 'font'
            [em, val, ok] = font_ref(em, ctx, sc, tag, v);
        case 'enum'
            val = enum_name(ctx, sc, tag, attrName, v, k.prefix);
            ok = ~isempty(val);
        case 'layout'
            e = enum_name(ctx, sc, tag, attrName, v, 'LV_LAYOUT_');
            ok = ~isempty(e);
            if ok
                % The layout setter takes a number, so the name is looked
                % up; as an expression it stays readable in written code.
                [em, val] = em.expr(em, 'PsychLVGL', {'Enum', e});
            end
        case 'unsupported'
            warn_unsupported(ctx, sc, tag, sprintf('style property "%s"', prop));
            ok = false;
        otherwise
            [val, ok] = to_int(ctx, sc, tag, attrName, v);
    end
end

function tf = style_prop_known(ctx, prop)
    tf = isvarname(prop) && isfield(ctx.ops, ['ObjSetStyle' camel(prop)]);
end

function [sel, ok] = selector(ctx, sc, tag, attrName, tokens)
% Parts and states, as the editor writes them after the property name or in
% a selector attribute. 0 is LV_PART_MAIN with the default state.
    parts = {'main', 'scrollbar', 'indicator', 'knob', 'selected', 'items', 'cursor', 'custom_first'};
    states = {'default', 'pressed', 'checked', 'hovered', 'scrolled', 'disabled', 'focused', ...
              'focus_key', 'edited', 'user_1', 'user_2', 'user_3', 'user_4'};
    names = {};
    ok = true;
    for k = 1:numel(tokens)
        t = strtrim(tokens{k});
        if isempty(t)
            continue;
        elseif any(strcmp(t, parts))
            names{end+1} = ['LV_PART_' upper(t)]; %#ok<AGROW>
        elseif any(strcmp(t, states))
            names{end+1} = ['LV_STATE_' upper(t)]; %#ok<AGROW>
        elseif strcmp(t, 'any')
            names{end+1} = 'LV_PART_ANY|LV_STATE_ANY'; %#ok<AGROW>
        else
            warn_value(ctx, sc, tag, attrName, t, 'not a part or state name');
            ok = false;
            sel = 0;
            return;
        end
    end
    if isempty(names)
        sel = 0;
    else
        sel = strjoin(names, '|');
    end
end

function em = apply_local_style(em, ctx, sc, ref, n, v, tag)
% style_bg_color, style_bg_color-pressed, style_bg_opa-indicator-pressed.
% The editor separates the selector with '-'; the removed 9.4 engine used
% ':'. Both are accepted.
    body = n(7:end);
    tokens = regexp(body, '[-:]', 'split');
    prop = tokens{1};
    if ~style_prop_known(ctx, prop)
        sk = style_kind(prop);
        if strcmp(sk.type, 'unsupported')
            warn_unsupported(ctx, sc, tag, sprintf('style property "%s"', prop));
        else
            warn_unknown_attr(ctx, sc, tag, n);
        end
        return;
    end
    [sel, ok] = selector(ctx, sc, tag, n, tokens(2:end));
    if ~ok
        return;
    end
    [em, val, ok] = style_value(em, ctx, sc, prop, v, tag, n);
    if ~ok
        return;
    end
    args = {['ObjSetStyle' camel(prop)], ref, val};
    if ~(isnumeric(sel) && sel == 0)
        args{end+1} = sel;
    end
    em = em.call(em, 'PsychLVGL', args, '');
end

function [em, st, ok] = style_ref(em, ctx, sc, tag, name)
% A named style, made on first use. "component.style" names a style of
% another component, as in LVGL.
    st = [];
    ok = false;
    owner = sc;
    key = name;
    dot = find(name == '.', 1, 'last');
    if ~isempty(dot)
        [def, found] = get_component(ctx, name(1:dot-1));
        if ~found
            warn(ctx, 'psychlvgl:XMLReference', 'unknown style "%s" on <%s> in %s', name, tag, sc.file);
            return;
        end
        [em, def] = prepare_component(em, ctx, def);
        owner = def.scope;
        key = name(dot+1:end);
    end
    s = owner;
    while ~isempty(s) && ~isKey(s.styles, key)
        s = s.up;
    end
    if isempty(s) && isKey(ctx.globals.styles, key)
        s = ctx.globals;
    end
    if isempty(s)
        warn(ctx, 'psychlvgl:XMLReference', 'unknown style "%s" on <%s> in %s; it is not applied', ...
             name, tag, sc.file);
        return;
    end
    e = s.styles(key);
    if isempty(e.ref)
        [em, e.ref] = em.call(em, 'PsychLVGL', {'StyleCreate'}, prefixed('style_', key));
        [names, vals] = raw_attrs(e.node);
        for k = 1:numel(names)
            p = names{k};
            if any(strcmp(p, {'name', 'help'}))
                continue;
            end
            [v, rok] = resolve(ctx, e.scope, vals{k});
            if ~rok
                continue;
            end
            if ~style_prop_known(ctx, p)
                sk = style_kind(p);
                if strcmp(sk.type, 'unsupported')
                    warn_unsupported(ctx, e.scope, 'style', sprintf('style property "%s"', p));
                else
                    warn_unknown_attr(ctx, e.scope, 'style', p);
                end
                continue;
            end
            [em, val, vok] = style_value(em, ctx, e.scope, p, v, 'style', p);
            if vok
                em = em.call(em, 'PsychLVGL', {'StyleSetProp', e.ref, p, val}, '');
            end
        end
        s.styles(key) = e;
    end
    st = e.ref;
    ok = true;
end

function em = apply_styles_attr(em, ctx, sc, ref, v, tag)
% The styles="name name:selector" attribute of the 9.4 format.
    items = regexp(strtrim(v), '\s+', 'split');
    for k = 1:numel(items)
        if isempty(items{k})
            continue;
        end
        tokens = regexp(items{k}, '[:|]', 'split');
        [sel, ok] = selector(ctx, sc, tag, 'styles', tokens(2:end));
        if ~ok
            continue;
        end
        [em, st, ok] = style_ref(em, ctx, sc, tag, tokens{1});
        if ok
            args = {'ObjAddStyle', ref, st};
            if ~(isnumeric(sel) && sel == 0)
                args{end+1} = sel; %#ok<AGROW>
            end
            em = em.call(em, 'PsychLVGL', args, '');
        end
    end
end

% ======================================================================
% fonts and images

function [em, f, ok] = font_ref(em, ctx, sc, tag, name)
    ok = true;
    if isKey(ctx.fonts, name)
        e = ctx.fonts(name);
        if isempty(e.ref)
            full = e.src;
            if ~plv_xml_is_absolute(full)
                full = fullfile(e.dir, e.src);
            end
            if exist(full, 'file') ~= 2
                warn(ctx, 'psychlvgl:XMLReference', 'font file %s of font "%s" does not exist', full, name);
                f = [];
                ok = false;
                return;
            end
            [em, p] = em.path(em, e.dir, e.src);
            [em, e.ref] = em.call(em, 'PsychLVGL', {'FontLoad', p, e.size}, prefixed('font_', name));
            ctx.fonts(name) = e;
        end
        f = e.ref;
        return;
    end
    % Built-in fonts by their LVGL symbol or by the FontList name.
    f = regexprep(name, '^lv_font_', '');
    if any(strcmp(f, ctx.fontList))
        return;
    end
    warn(ctx, 'psychlvgl:XMLReference', ...
         'unknown font "%s" on <%s> in %s: not declared in <fonts> and not one of %s', ...
         name, tag, sc.file, strjoin(ctx.fontList', ', '));
    f = [];
    ok = false;
end

function s = prefixed(prefix, name)
% A variable name hint for the written code, without doubling a prefix the
% XML name already has (style_card, not style_style_card).
    if strncmp(name, prefix, numel(prefix))
        s = name;
    else
        s = [prefix name];
    end
end

function [em, img, ok] = image_ref(em, ctx, sc, tag, name)
    ok = true;
    if isKey(ctx.images, name)
        e = ctx.images(name);
        base = e.dir;
        rel = e.src;
        key = ['@' name];
    else
        % Not declared: a path relative to the asset folder, as a <file>
        % image would give.
        base = asset_dir(ctx, sc);
        rel = name;
        key = name;
    end
    full = rel;
    if ~plv_xml_is_absolute(full)
        full = fullfile(base, rel);
    end
    if isKey(ctx.imgfiles, key)
        img = ctx.imgfiles(key);
        return;
    end
    if exist(full, 'file') ~= 2
        warn(ctx, 'psychlvgl:XMLReference', ...
             'image "%s" on <%s> in %s: not declared in <images>, and %s does not exist', ...
             name, tag, sc.file, full);
        img = [];
        ok = false;
        return;
    end
    [em, p] = em.path(em, base, rel);
    [em, img] = em.call(em, 'PsychLVGLImageFromFile', {p}, prefixed('img_', regexprep(name, '\.[^.]*$', '')));
    ctx.imgfiles(key) = img;
end

% ======================================================================
% child directives: styles, bindings, subject events, chart and table parts

function [em, handled] = directive(em, ctx, sc, c, ref, kind, info)
    handled = true;
    tag = c.tag;
    [names, vals] = gather(ctx, sc, c, {});
    switch tag
        case 'style'
            [name, h] = attr(names, vals, 'name');
            if ~h
                return;      % a prop without a value, as LVGL skips it
            end
            [sel, ok] = selector(ctx, sc, tag, 'selector', split_sel(attr(names, vals, 'selector')));
            if ~ok
                return;
            end
            [em, st, ok] = style_ref(em, ctx, sc, tag, name);
            if ok
                args = {'ObjAddStyle', ref, st};
                if ~(isnumeric(sel) && sel == 0)
                    args{end+1} = sel;
                end
                em = em.call(em, 'PsychLVGL', args, '');
            end
        case 'remove_style'
            [sel, ok] = selector(ctx, sc, tag, 'selector', split_sel(attr(names, vals, 'selector')));
            if ~ok
                return;
            end
            [name, h] = attr(names, vals, 'name');
            st = 0;
            if h
                [em, st, ok] = style_ref(em, ctx, sc, tag, name);
                if ~ok
                    return;
                end
            end
            args = {'ObjRemoveStyle', ref, st};
            if ~(isnumeric(sel) && sel == 0)
                args{end+1} = sel;
            end
            em = em.call(em, 'PsychLVGL', args, '');
        case 'remove_style_all'
            em = em.call(em, 'PsychLVGL', {'ObjRemoveStyleAll', ref}, '');
        case {'bind_flag_if_eq', 'bind_flag_if_not_eq', 'bind_flag_if_gt', 'bind_flag_if_ge', ...
              'bind_flag_if_lt', 'bind_flag_if_le', 'bind_state_if_eq', 'bind_state_if_not_eq', ...
              'bind_state_if_gt', 'bind_state_if_ge', 'bind_state_if_lt', 'bind_state_if_le'}
            isFlag = strncmp(tag, 'bind_flag', 9);
            op = regexprep(tag, '^bind_(flag|state)_if_', '');
            [s, hs] = attr(names, vals, 'subject');
            if isFlag
                [what, hw] = attr(names, vals, 'flag');
                prefix = 'LV_OBJ_FLAG_';
            else
                [what, hw] = attr(names, vals, 'state');
                prefix = 'LV_STATE_';
            end
            [rv, hr] = attr(names, vals, 'ref_value');
            if ~(hs && hw && hr)
                warn(ctx, 'psychlvgl:XMLValue', '<%s> in %s needs subject, %s and ref_value', ...
                     tag, sc.file, regexprep(tag, '^bind_(flag|state).*$', '$1'));
                return;
            end
            if isFlag
                % The per-flag setter, as for the flag attributes.
                e = ['ObjSet' camel(what)];
                if ~isfield(ctx.ops, e)
                    warn_value(ctx, sc, tag, 'flag', what, 'not an object flag');
                    e = '';
                end
            else
                e = enum_name(ctx, sc, tag, 'state', what, prefix);
            end
            [x, ok] = to_int(ctx, sc, tag, 'ref_value', rv);
            if ~isempty(e) && ok && subject_ok(ctx, sc, tag, s)
                if isFlag
                    em = em.subjects(em, 'bind', {'flag', ref, s, e, op, x});
                else
                    em = em.subjects(em, 'bind', {'state', ref, s, e, op, x});
                end
            end
        case 'bind_style'
            [name, hn] = attr(names, vals, 'name');
            [s, hs] = attr(names, vals, 'subject');
            [rv, hr] = attr(names, vals, 'ref_value');
            if ~(hn && hs && hr)
                warn(ctx, 'psychlvgl:XMLValue', '<bind_style> in %s needs name, subject and ref_value', sc.file);
                return;
            end
            [sel, ok] = selector(ctx, sc, tag, 'selector', split_sel(attr(names, vals, 'selector')));
            [x, ok2] = to_int(ctx, sc, tag, 'ref_value', rv);
            if ~(ok && ok2 && subject_ok(ctx, sc, tag, s))
                return;
            end
            [em, st, ok] = style_ref(em, ctx, sc, tag, name);
            if ok
                em = em.subjects(em, 'bind', {'style', ref, s, st, sel, x});
            end
        case 'bind_style_prop'
            [p, hp] = attr(names, vals, 'prop');
            [s, hs] = attr(names, vals, 'subject');
            if ~(hp && hs)
                warn(ctx, 'psychlvgl:XMLValue', '<bind_style_prop> in %s needs prop and subject', sc.file);
                return;
            end
            sk = style_kind(p);
            if ~style_prop_known(ctx, p) || ~any(strcmp(sk.type, {'int', 'opa'}))
                warn_unsupported(ctx, sc, tag, sprintf('binding style property "%s"', p));
                return;
            end
            [sel, ok] = selector(ctx, sc, tag, 'selector', split_sel(attr(names, vals, 'selector')));
            if ok && subject_ok(ctx, sc, tag, s)
                em = em.subjects(em, 'bind', {'style_prop', ref, s, ['ObjSetStyle' camel(p)], sel});
            end
        case {'subject_set_int_event', 'subject_set_float_event', 'subject_set_string_event', ...
              'subject_toggle_event', 'subject_increment_event'}
            em = subject_event(em, ctx, sc, tag, names, vals, ref);
        case {'lv_chart-series', 'lv_chart-axis', 'lv_chart-cursor'}
            if ~strcmp(kind, 'chart')
                handled = false;
                return;
            end
            em = chart_part(em, ctx, sc, tag, names, vals, ref, info);
        case {'lv_table-column', 'lv_table-cell'}
            if ~strcmp(kind, 'table')
                handled = false;
                return;
            end
            em = table_part(em, ctx, sc, tag, names, vals, ref);
        case {'event_cb', 'screen_load_event', 'screen_create_event', 'play_timeline_event', ...
              'lv_dropdown-list'}
            warn_unsupported(ctx, sc, 'view', sprintf('<%s>', tag));
        otherwise
            handled = false;
    end
end

function t = split_sel(s)
    if isempty(s)
        t = {};
    else
        t = regexp(s, '[|:-]', 'split');
    end
end

function em = subject_event(em, ctx, sc, tag, names, vals, ref)
    [s, hs] = attr(names, vals, 'subject');
    if ~hs
        warn(ctx, 'psychlvgl:XMLValue', '<%s> in %s has no subject', tag, sc.file);
        return;
    end
    if ~subject_ok(ctx, sc, tag, s)
        return;
    end
    [trig, ht] = attr(names, vals, 'trigger');
    if ~ht
        trig = 'clicked';
    end
    if ~enum_exists(ctx, ['LV_EVENT_' upper(trig)])
        warn_value(ctx, sc, tag, 'trigger', trig, 'not an LVGL event');
        return;
    end
    ev = upper(trig);
    switch tag
        case 'subject_toggle_event'
            em = em.subjects(em, 'trigger', {ref, ev, 'toggle', s});
        case 'subject_set_string_event'
            em = em.subjects(em, 'trigger', {ref, ev, 'set', s, attr(names, vals, 'value')});
        case {'subject_set_int_event', 'subject_set_float_event'}
            v = str2double(attr(names, vals, 'value'));
            if isnan(v)
                warn_value(ctx, sc, tag, 'value', attr(names, vals, 'value'), 'not a number');
                return;
            end
            em = em.subjects(em, 'trigger', {ref, ev, 'set', s, v});
        case 'subject_increment_event'
            step = attr_default(names, vals, 'step', 1);
            lo = attr_default(names, vals, 'min_value', -Inf);
            hi = attr_default(names, vals, 'max_value', Inf);
            [r, hr] = attr(names, vals, 'rollover');
            em = em.subjects(em, 'trigger', {ref, ev, 'increment', s, step, lo, hi, hr && to_bool(r)});
    end
end

function v = attr_default(names, vals, key, dflt)
    [s, h] = attr(names, vals, key);
    v = dflt;
    if h && ~isnan(str2double(s))
        v = str2double(s);
    end
end

function em = chart_part(em, ctx, sc, tag, names, vals, chart, info)
    switch tag
        case 'lv_chart-series'
            [col, hc] = attr(names, vals, 'color');
            c = [255 0 0];
            if hc
                [c, ok] = to_color(col);
                if ~ok
                    warn_value(ctx, sc, tag, 'color', col, 'not a color of the form 0xRRGGBB');
                    return;
                end
            end
            [ax, ha] = attr(names, vals, 'axis');
            if ~ha
                ax = 'primary_y';
            end
            e = enum_name(ctx, sc, tag, 'axis', ax, 'LV_CHART_AXIS_');
            if isempty(e)
                return;
            end
            [name, hn] = attr(names, vals, 'name');
            hint = 'series';
            if hn
                hint = name;
            end
            [em, ser] = em.call(em, 'PsychLVGL', {'ChartAddSeries', chart, c, e}, hint);
            if hn
                em = register_name(em, ctx, ser, name, false);
            end
            [vs, hv] = attr(names, vals, 'values');
            if hv
                items = regexp(strtrim(vs), '[\s,]+', 'split');
                x = str2double(items);
                x(strcmpi(items, 'none')) = NaN;
                if numel(x) > info.pointCount
                    warn_value(ctx, sc, tag, 'values', vs, ...
                               sprintf('the chart has %d points; the rest are dropped', info.pointCount));
                    x = x(1:info.pointCount);
                end
                em = em.call(em, 'PsychLVGL', {'ChartSetValues', chart, ser, x}, '');
            end
            others = setdiff(names, {'color', 'axis', 'values', 'name'});
            for k = 1:numel(others)
                warn_unknown_attr(ctx, sc, tag, others{k});
            end
        case 'lv_chart-axis'
            [ax, ha] = attr(names, vals, 'axis');
            if ~ha
                warn(ctx, 'psychlvgl:XMLValue', '<%s> in %s has no axis', tag, sc.file);
                return;
            end
            e = enum_name(ctx, sc, tag, 'axis', ax, 'LV_CHART_AXIS_');
            lo = attr_default(names, vals, 'min_value', 0);
            hi = attr_default(names, vals, 'max_value', 100);
            if ~isempty(e)
                em = em.call(em, 'PsychLVGL', {'ChartSetAxisRange', chart, e, lo, hi}, '');
            end
        case 'lv_chart-cursor'
            [col, hc] = attr(names, vals, 'color');
            c = [0 0 255];
            if hc
                [c, ok] = to_color(col);
                if ~ok
                    warn_value(ctx, sc, tag, 'color', col, 'not a color of the form 0xRRGGBB');
                    return;
                end
            end
            [d, hd] = attr(names, vals, 'dir');
            if ~hd
                d = 'all';
            end
            e = enum_name(ctx, sc, tag, 'dir', d, 'LV_DIR_');
            if isempty(e)
                return;
            end
            [em, cur] = em.call(em, 'PsychLVGL', {'ChartAddCursor', chart, c, e}, 'cursor');
            [px, hx] = attr(names, vals, 'pos_x');
            if hx && ~isnan(str2double(px))
                em = em.call(em, 'PsychLVGL', {'ChartSetCursorPosX', chart, cur, str2double(px)}, '');
            end
            [py, hy] = attr(names, vals, 'pos_y');
            if hy && ~isnan(str2double(py))
                em = em.call(em, 'PsychLVGL', {'ChartSetCursorPosY', chart, cur, str2double(py)}, '');
            end
    end
end

function em = table_part(em, ctx, sc, tag, names, vals, t)
    switch tag
        case 'lv_table-column'
            col = attr_default(names, vals, 'column', NaN);
            [w, hw] = attr(names, vals, 'width');
            if isnan(col) || ~hw
                warn(ctx, 'psychlvgl:XMLValue', '<%s> in %s needs column and width', tag, sc.file);
                return;
            end
            [x, ok] = to_int(ctx, sc, tag, 'width', w);
            if ok
                em = em.call(em, 'PsychLVGL', {'TableSetColumnWidth', t, col, x}, '');
            end
        case 'lv_table-cell'
            row = attr_default(names, vals, 'row', NaN);
            col = attr_default(names, vals, 'column', NaN);
            if isnan(row) || isnan(col)
                warn(ctx, 'psychlvgl:XMLValue', '<%s> in %s needs row and column', tag, sc.file);
                return;
            end
            [v, hv] = attr(names, vals, 'value');
            if hv
                em = em.call(em, 'PsychLVGL', {'TableSetCellValue', t, row, col, v}, '');
            end
            [c, hc] = attr(names, vals, 'ctrl');
            if hc
                e = enum_name(ctx, sc, tag, 'ctrl', c, 'LV_TABLE_CELL_CTRL_');
                if ~isempty(e)
                    em = em.call(em, 'PsychLVGL', {'TableSetCellCtrl', t, row, col, e}, '');
                end
            end
    end
end
