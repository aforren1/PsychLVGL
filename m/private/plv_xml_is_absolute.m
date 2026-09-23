function tf = plv_xml_is_absolute(p)
% PLV_XML_IS_ABSOLUTE  True for a path that does not need a base directory.
    tf = ~isempty(p) && (p(1) == '/' || p(1) == '\' || ...
         (numel(p) >= 2 && p(2) == ':' && isletter(p(1))));
end
