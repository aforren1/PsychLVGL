function out = plv_xml_collect(id, msg)
% PLV_XML_COLLECT  Warn handler for the XML tests: records instead of warning.
%   opts.Warn = @plv_xml_collect records each call; plv_xml_collect('reset')
%   empties the record and W = plv_xml_collect('get') returns it as a struct
%   array with fields id and msg. A global, because Octave does not share a
%   parent workspace with nested functions.

    global PLV_XML_WARNINGS %#ok<GVMIS>
    if nargin == 1 && strcmp(id, 'reset')
        PLV_XML_WARNINGS = struct('id', {}, 'msg', {});
        return;
    end
    if nargin == 1 && strcmp(id, 'get')
        if isempty(PLV_XML_WARNINGS)
            PLV_XML_WARNINGS = struct('id', {}, 'msg', {});
        end
        out = PLV_XML_WARNINGS;
        return;
    end
    if isempty(PLV_XML_WARNINGS)
        PLV_XML_WARNINGS = struct('id', {}, 'msg', {});
    end
    PLV_XML_WARNINGS(end+1) = struct('id', id, 'msg', msg);
end
