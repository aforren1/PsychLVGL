function em = plv_xml_emit_write(assetDir)
% PLV_XML_EMIT_WRITE  Emitter backend that writes M code instead of calling.
%   The same interface as plv_xml_emit_exec, used by PsychLVGLXMLToM. A
%   reference here is a struct with one field, code, which holds a variable
%   name or an expression; a literal argument is any other value. The lines
%   collect in em.lines, which grows by doubling so the walk stays linear.

    em = struct();
    em.mode = 'write';
    em.assetDir = assetDir;
    em.lines = cell(1, 256);
    em.nlines = 0;
    em.vars = struct();          % variable name -> 1, for unique names
    em.call = @write_call;
    em.expr = @write_expr;
    em.setnamed = @write_setnamed;
    em.subjects = @write_subjects;
    em.path = @write_path;
    em.comment = @write_comment;
end

function em = put(em, line)
    if em.nlines == numel(em.lines)
        em.lines{2 * numel(em.lines)} = [];
    end
    em.nlines = em.nlines + 1;
    em.lines{em.nlines} = line;
end

function [em, v] = new_var(em, hint)
% Hints come from XML names, so they are sanitized and made unique here.
% The prefix keeps them apart from the function's own variables.
    base = regexprep(hint, '[^A-Za-z0-9_]', '_');
    if isempty(base) || ~isletter(base(1))
        base = ['v' base];
    end
    base = base(1:min(end, 50));
    v = base;
    k = 1;
    while isfield(em.vars, v) || any(strcmp(v, {'parent', 'assetDir', 'named', 'root'})) ...
            || iskeyword(v)
        k = k + 1;
        v = sprintf('%s_%d', base, k);
    end
    em.vars.(v) = 1;
end

function s = args_text(fn, args)
    parts = cell(1, numel(args));
    for k = 1:numel(args)
        parts{k} = plv_xml_literal(args{k});
    end
    if isempty(parts)
        s = sprintf('%s()', fn);
    else
        s = sprintf('%s(%s)', fn, strjoin(parts, ', '));
    end
end

function [em, r] = write_call(em, fn, args, hint)
    rhs = args_text(fn, args);
    if isempty(hint)
        em = put(em, [rhs ';']);
        r = [];
    else
        [em, v] = new_var(em, hint);
        em = put(em, sprintf('%s = %s;', v, rhs));
        r = struct('code', v);
    end
end

function [em, r] = write_expr(em, fn, args)
    r = struct('code', args_text(fn, args));
end

function em = write_setnamed(em, key, r)
    em = put(em, sprintf('named.%s = %s;', key, plv_xml_literal(r)));
end

function em = write_subjects(em, verb, args)
    if strcmp(verb, 'create')
        em = put(em, 'named.subjects = PsychLVGLSubjects(''create'');');
        return;
    end
    em = put(em, sprintf('named.subjects = %s;', ...
        args_text('PsychLVGLSubjects', [{verb, struct('code', 'named.subjects')}, args])));
end

function [em, p] = write_path(em, baseDir, rel)
% Paths under the asset directory stay relative to the generated function's
% assetDir argument, so the generated file moves with its assets.
    if plv_xml_is_absolute(rel)
        p = rel;
    elseif strcmp(baseDir, em.assetDir)
        p = struct('code', sprintf('fullfile(assetDir, %s)', plv_xml_literal(rel)));
    else
        p = fullfile(baseDir, rel);
    end
end

function em = write_comment(em, text)
    em = put(em, ['% ' strrep(strrep(text, sprintf('\n'), ' '), sprintf('\r'), ' ')]);
end
