function em = plv_xml_emit_exec(assetDir)
% PLV_XML_EMIT_EXEC  Emitter backend that runs each call at once.
%   The interpreter (plv_xml_run) talks to an emitter only, so that
%   PsychLVGLLoadXML and PsychLVGLXMLToM share one walk of the XML and cannot
%   drift apart. This backend is the one PsychLVGLLoadXML uses: a reference
%   is the handle itself, a double.
%
%   Every operation takes the emitter and returns it, because MATLAB structs
%   are values. plv_xml_emit_write has the same fields.

    em = struct();
    em.mode = 'exec';
    em.assetDir = assetDir;
    % named.subjects comes first, as in the code plv_xml_emit_write writes,
    % so both front ends return the same field order.
    em.named = struct();
    em.call = @exec_call;
    em.expr = @exec_expr;
    em.setnamed = @exec_setnamed;
    em.subjects = @exec_subjects;
    em.path = @exec_path;
    em.comment = @exec_comment;
end

function [em, r] = exec_call(em, fn, args, hint)
% A call with a hint is one whose result the walk keeps; the others return
% nothing, and asking a MEX subcommand for an output it does not have fails.
    if isempty(hint)
        feval(fn, args{:});
        r = [];
    else
        r = feval(fn, args{:});
    end
end

function [em, r] = exec_expr(em, fn, args)
    r = feval(fn, args{:});
end

function em = exec_setnamed(em, key, r)
    em.named.(key) = r;
end

function em = exec_subjects(em, verb, args)
    if strcmp(verb, 'create')
        em.named.subjects = PsychLVGLSubjects('create');
    else
        em.named.subjects = PsychLVGLSubjects(verb, em.named.subjects, args{:});
    end
end

function [em, p] = exec_path(em, baseDir, rel)
    if plv_xml_is_absolute(rel)
        p = rel;
    else
        p = fullfile(baseDir, rel);
    end
end

function em = exec_comment(em, text) %#ok<INUSD>
end
