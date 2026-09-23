function s = plv_xml_literal(x)
% PLV_XML_LITERAL  M source text for a value, for PsychLVGLXMLToM.
%   A struct with a code field is a reference that the write emitter made
%   and is copied as is. Text with line breaks becomes a concatenation with
%   char(10), because a quoted M string cannot hold one.
    if isstruct(x) && isfield(x, 'code')
        s = x.code;
    elseif ischar(x)
        if isempty(x)
            s = '''''';
            return;
        end
        x = x(:)';
        ctl = find(x < 32);
        if isempty(ctl)
            s = ['''' strrep(x, '''', '''''') ''''];
            return;
        end
        parts = {};
        start = 1;
        for k = ctl
            if k > start
                parts{end+1} = ['''' strrep(x(start:k-1), '''', '''''') '''']; %#ok<AGROW>
            end
            parts{end+1} = sprintf('char(%d)', double(x(k))); %#ok<AGROW>
            start = k + 1;
        end
        if start <= numel(x)
            parts{end+1} = ['''' strrep(x(start:end), '''', '''''') ''''];
        end
        s = ['[' strjoin(parts, ' ') ']'];
    elseif islogical(x) && isscalar(x)
        if x; s = 'true'; else; s = 'false'; end
    elseif isnumeric(x) || islogical(x)
        x = double(x);
        if isscalar(x)
            s = num_text(x);
        else
            p = cell(1, numel(x));
            for k = 1:numel(x)
                p{k} = num_text(x(k));
            end
            s = ['[' strjoin(p, ' ') ']'];
        end
    else
        error('psychlvgl:Type', 'PsychLVGLXMLToM cannot write a value of class %s', class(x));
    end
end

function s = num_text(v)
    if isnan(v)
        s = 'NaN';
    elseif v == round(v) && abs(v) < 2^53
        s = sprintf('%d', v);
    else
        s = sprintf('%.17g', v);
    end
end
