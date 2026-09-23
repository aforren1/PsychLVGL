function test_xml_parse()
% TEST_XML_PARSE  ParseXML: the node tree, attribute names that need a new
%   name, text nodes, empty elements, files and parse errors. ParseXML needs
%   no Init.

    fx = fullfile(fileparts(mfilename('fullpath')), 'xml');

    t = PsychLVGL('ParseXML', '<screen a="1"><view/></screen>');
    plv_eq('one root node', size(t), [1 1]);
    plv_eq('the node fields', fieldnames(t)', {'tag', 'attributes', 'attr_names', 'text', 'children'});
    plv_eq('tag', t.tag, 'screen');
    plv_eq('attribute values are char', t.attributes.a, '1');
    plv_assert('no rename, so attr_names is empty', isempty(t.attr_names) && iscell(t.attr_names));
    plv_eq('an element without text has empty text', t.text, '');
    plv_eq('the children are a struct array', size(t.children), [1 1]);
    plv_eq('the child tag', t.children.tag, 'view');
    plv_assert('a leaf has an empty children struct with the same fields', ...
               isstruct(t.children.children) && isempty(t.children.children) && ...
               isequal(fieldnames(t.children.children)', fieldnames(t)'));
    plv_eq('a leaf has no attributes', numel(fieldnames(t.children.attributes)), 0);

    % Attribute names that are not MATLAB field names.
    t = PsychLVGL('ParseXML', ['<lv_label name="x" bind_text-fmt="%d" end="3" _p="4" ' ...
                                'xmlns:q="u" a-b="1" a_b="2"/>']);
    plv_eq('sanitized field names', fieldnames(t.attributes)', ...
           {'name', 'bind_text_fmt', 'xend', 'x_p', 'xmlns_q', 'a_b', 'a_b_2'});
    plv_eq('a renamed attribute keeps its value', t.attributes.bind_text_fmt, '%d');
    plv_eq('attr_names keeps the originals in field order', t.attr_names, ...
           {'name', 'bind_text-fmt', 'end', '_p', 'xmlns:q', 'a-b', 'a_b'});
    long = repmat('a', 1, 80);
    t = PsychLVGL('ParseXML', sprintf('<x %s="1" %sb="2"/>', long, long));
    f = fieldnames(t.attributes);
    plv_assert('long names are cut to 63 characters and stay unique', ...
               numel(f) == 2 && all(cellfun(@numel, f) <= 63) && ~strcmp(f{1}, f{2}));

    % Text: trimmed, CDATA included, fragments around children joined.
    t = PsychLVGL('ParseXML', '<a>  Hello <b/> <![CDATA[ big <world> ]]>  </a>');
    plv_eq('text is trimmed and joined', t.text, 'Hello big <world>');
    t = PsychLVGL('ParseXML', '<a>x &amp; y &#65;</a>');
    plv_eq('entities are decoded', t.text, 'x & y A');
    t = PsychLVGL('ParseXML', '<a v="One&#10;Two"/>');
    plv_eq('a character reference keeps its newline', t.attributes.v, sprintf('One\nTwo'));

    % Comments, declarations and processing instructions are not nodes.
    t = PsychLVGL('ParseXML', '<?xml version="1.0"?><!-- c --><a><!-- d --><?pi x?><b/></a>');
    plv_eq('only elements become nodes', {t.tag, t.children.tag}, {'a', 'b'});

    % Sibling order and a wide tree.
    t = PsychLVGL('ParseXML', '<a><b i="1"/><c/><b i="2"/></a>');
    plv_eq('children keep document order', {t.children.tag}, {'b', 'c', 'b'});
    xml = ['<a>' repmat('<b/>', 1, 500) '</a>'];
    t = PsychLVGL('ParseXML', xml);
    plv_eq('500 children', numel(t.children), 500);

    % Non-ASCII text survives the round trip in both engines.
    % Octave char is UTF-8 bytes; MATLAB char is UTF-16, where the last
    % character is a surrogate pair, U+1F600.
    if exist('OCTAVE_VERSION', 'builtin')
        s = char([99 97 102 195 169 240 159 152 128]);
    else
        s = char([99 97 102 233 55357 56832]);
    end
    t = PsychLVGL('ParseXML', ['<a t="' s '">' s '</a>']);
    plv_eq('non-ASCII attribute value round trip', double(t.attributes.t), double(s));
    plv_eq('non-ASCII text round trip', double(t.text), double(s));

    % A file, detected because the argument names one.
    t = PsychLVGL('ParseXML', fullfile(fx, 'my_button.xml'));
    plv_eq('a file parses', t.tag, 'component');
    plv_eq('file children', {t.children.tag}, {'consts', 'api', 'styles', 'view'});
    v = t.children(4);
    plv_eq('view attributes from a file', v.attributes.extends, 'lv_button');
    plv_eq('grandchildren from a file', {v.children.tag}, {'style', 'lv_label'});

    % Errors.
    plv_throws('mismatched tags', 'psychlvgl:XML', @() PsychLVGL('ParseXML', '<a><b></a>'));
    try
        PsychLVGL('ParseXML', sprintf('<a>\n<b x=1/></a>'));
        plv_assert('a parse error raises', false);
    catch err
        plv_eq('parse error id', err.identifier, 'psychlvgl:XML');
        plv_assert('the message has the description, offset, line and column', ...
                   ~isempty(strfind(err.message, 'offset')) && ~isempty(strfind(err.message, 'line 2')));
    end
    plv_throws('a missing file', 'psychlvgl:XML', @() PsychLVGL('ParseXML', 'no_such_file.xml'));
    plv_throws('text without an element', 'psychlvgl:XML', @() PsychLVGL('ParseXML', '<!-- only -->'));
    plv_throws('a number is not accepted', 'psychlvgl:Type', @() PsychLVGL('ParseXML', 3));
    plv_throws('no argument', 'psychlvgl:Usage', @() PsychLVGL('ParseXML'));
    deep = [repmat('<a>', 1, 300) repmat('</a>', 1, 300)];
    plv_throws('a document deeper than 256 levels', 'psychlvgl:XML', @() PsychLVGL('ParseXML', deep));
    t = PsychLVGL('ParseXML', '<a/>');
    plv_eq('ParseXML works again after an error', t.tag, 'a');
end
