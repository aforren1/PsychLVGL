function test_xml_load()
% TEST_XML_LOAD  PsychLVGLLoadXML and PsychLVGLXMLToM on the fixtures in
%   tests/xml: handles and names, sizes, styles with selectors, constants,
%   component props, fonts and images, one warning per distinct problem, and
%   generated code that builds the same interface.

    fx = fullfile(fileparts(mfilename('fullpath')), 'xml');
    opts = struct('Warn', @plv_xml_collect);

    PsychLVGL('Init', 480, 480);
    c = onCleanup(@() PsychLVGL('Shutdown')); %#ok<NASGU>

    % ------------------------------------------------------------ main.xml
    plv_xml_collect('reset');
    scr = PsychLVGL('ScreenCreate');
    [root, n] = PsychLVGLLoadXML(fullfile(fx, 'main.xml'), scr, opts);
    w = plv_xml_collect('get');
    plv_eq('main.xml loads without a warning', numel(w), 0);
    for k = 1:numel(w)
        fprintf(2, '        %s: %s\n', w(k).id, w(k).msg);
    end
    plv_eq('a screen fills the parent it is given', root, scr);
    expected = {'subjects', 'title', 'card', 'card_label', 'box', 'tall_box', 'slider', 'bar', ...
                'arc', 'sw', 'cb', 'dd', 'roller', 'ta', 'spin', 'table', 'chart', 'series_a', ...
                'img', 'ok_button', 'caption', 'plain_button', 'caption_2', 'card2', 'caption_3'};
    plv_eq('named handles in document order, repeated names numbered', fieldnames(n)', expected);
    ok = true;
    for k = 2:numel(expected)
        ok = ok && PsychLVGL('IsValid', n.(expected{k}));
    end
    plv_assert('every named handle is valid', ok);
    plv_eq('ObjSetName makes names findable', PsychLVGL('ObjFindByName', scr, 'slider'), n.slider);

    PsychLVGL('ScreenLoad', scr);
    layout();

    plv_eq('a constant from globals.xml', PsychLVGL('LabelGetText', n.title), 'Fixture title');
    plv_assert('the TTF font of <fonts> sizes the title', PsychLVGL('ObjGetHeight', n.title) >= 24);
    plv_eq('a global style with a chained constant sets the width', PsychLVGL('ObjGetWidth', n.card), 200);
    plv_eq('a local attribute sets the height', PsychLVGL('ObjGetHeight', n.card), 80);
    plv_eq('x and y', [PsychLVGL('ObjGetX', n.card), PsychLVGL('ObjGetY', n.card)], [4 40]);
    plv_eq('a percentage width', PsychLVGL('ObjGetWidth', n.box), 240);
    plv_eq('the styles attribute applies a local style', PsychLVGL('ObjGetHeight', n.tall_box), 33);
    plv_assert('scrollable="false" clears the flag', ~PsychLVGL('ObjHasFlag', n.box, 'LV_OBJ_FLAG_SCROLLABLE'));

    PsychLVGL('ObjAddState', n.card, 'LV_STATE_PRESSED');
    layout();
    plv_eq('a style added with selector="pressed" applies when pressed', PsychLVGL('ObjGetWidth', n.card), 150);
    PsychLVGL('ObjRemoveState', n.card, 'LV_STATE_PRESSED');
    layout();
    plv_eq('and not otherwise', PsychLVGL('ObjGetWidth', n.card), 200);
    PsychLVGL('ObjAddState', n.box, 'LV_STATE_CHECKED');
    layout();
    plv_eq('style_width-checked applies in the checked state', PsychLVGL('ObjGetWidth', n.box), 77);

    plv_eq('slider range with a screen constant', ...
           [PsychLVGL('SliderGetMinValue', n.slider), PsychLVGL('SliderGetMaxValue', n.slider)], [10 200]);
    plv_eq('slider value after its range', PsychLVGL('SliderGetValue', n.slider), 120);
    plv_eq('bar value', PsychLVGL('BarGetValue', n.bar), 25);
    plv_eq('arc value', PsychLVGL('ArcGetValue', n.arc), 30);
    plv_assert('checked="true" on a switch', PsychLVGL('ObjHasState', n.sw, 'LV_STATE_CHECKED'));
    plv_eq('checkbox text', PsychLVGL('CheckboxGetText', n.cb), 'Check me');
    plv_eq('dropdown options with a newline reference', PsychLVGL('DropdownGetSelectedStr', n.dd), 'Three');
    plv_eq('roller selection', PsychLVGL('RollerGetSelected', n.roller), 1);
    plv_eq('textarea text', PsychLVGL('TextareaGetText', n.ta), 'hello');
    plv_eq('spinbox value', PsychLVGL('SpinboxGetValue', n.spin), 42);
    plv_eq('a table cell', PsychLVGL('TableGetCellValue', n.table, 1, 1), 'x11');
    plv_eq('chart point count from a constant', PsychLVGL('ChartGetPointCount', n.chart), 12);
    v = PsychLVGL('ChartGetValues', n.chart, n.series_a);
    plv_eq('chart series values, the rest gaps', v, [1 2 3 4 NaN(1, 8)]);
    plv_eq('an image from <images>', ...
           [PsychLVGL('ImageGetSrcWidth', n.img), PsychLVGL('ImageGetSrcHeight', n.img)], [16 16]);

    plv_eq('a component prop', PsychLVGL('LabelGetText', n.caption), 'OK');
    plv_eq('a component prop default', PsychLVGL('LabelGetText', n.caption_2), 'Press');
    plv_eq('a prop passed through a component that extends one', ...
           PsychLVGL('LabelGetText', n.caption_3), 'Info');
    plv_eq('a component child sits in the instance', PsychLVGL('ObjGetParent', n.caption), n.ok_button);
    plv_eq('component size from a prop default and a local constant', ...
           [PsychLVGL('ObjGetWidth', n.ok_button), PsychLVGL('ObjGetHeight', n.ok_button)], [120 40]);
    plv_eq('an extending component overrides a prop', PsychLVGL('ObjGetWidth', n.card2), 180);
    plv_eq('instance position', [PsychLVGL('ObjGetX', n.card2), PsychLVGL('ObjGetY', n.card2)], [340 160]);

    % ------------------------------------------------ PsychLVGLXMLToM
    gen = [tempname() '.m'];
    [gd, gname] = fileparts(gen);
    gname = ['plv_gen_' regexprep(gname, '[^A-Za-z0-9]', '')];
    gen = fullfile(gd, [gname '.m']);
    cg = onCleanup(@() delete_if(gen)); %#ok<NASGU>
    plv_xml_collect('reset');
    PsychLVGLXMLToM(fullfile(fx, 'main.xml'), gen, opts);
    plv_eq('writing warns as loading does', numel(plv_xml_collect('get')), 0);
    text = fileread(gen);
    plv_assert('the file is a function of that name', ...
               strncmp(text, sprintf('function [root, named] = %s(parent, assetDir)', gname), 40 + numel(gname)));
    plv_assert('the file has the local style setter with its selector', ...
               ~isempty(strfind(text, 'PsychLVGL(''ObjSetStyleWidth'', box, 77, ''LV_STATE_CHECKED'');')));
    plv_assert('asset paths are relative to assetDir', ~isempty(strfind(text, 'fullfile(assetDir, ''images/checker.png'')')));
    scr2 = PsychLVGL('ScreenCreate');
    [root2, n2] = plv_run_generated(gen, scr2);
    plv_eq('the generated function returns its parent for a screen', root2, scr2);
    plv_eq('the generated function returns the same names', fieldnames(n2)', fieldnames(n)');
    PsychLVGL('ScreenLoad', scr2);
    layout();
    plv_eq('the generated interface has the same sizes', ...
           [PsychLVGL('ObjGetWidth', n2.card), PsychLVGL('ObjGetWidth', n2.box), ...
            PsychLVGL('ObjGetWidth', n2.card2), PsychLVGL('ObjGetHeight', n2.tall_box)], [200 240 180 33]);
    plv_eq('the generated interface has the same texts', ...
           {PsychLVGL('LabelGetText', n2.caption), PsychLVGL('LabelGetText', n2.caption_3), ...
            PsychLVGL('LabelGetText', n2.title)}, {'OK', 'Info', 'Fixture title'});
    plv_eq('the generated subject table matches', n2.subjects.names, n.subjects.names);
    plv_throws('an output name that is no function name', 'psychlvgl:Usage', ...
               @() PsychLVGLXMLToM(fullfile(fx, 'main.xml'), fullfile(gd, '1bad.m'), opts));

    % ------------------------------------------- one warning per problem
    plv_xml_collect('reset');
    [~, nu] = PsychLVGLLoadXML(fullfile(fx, 'unknown.xml'), PsychLVGL('ScreenCreate'), opts);
    w = plv_xml_collect('get');
    ids = {w.id};
    plv_eq('unknown elements and attributes, once each', sum(strcmp(ids, 'psychlvgl:XMLUnknown')), 4);
    plv_eq('dangling references, once each', sum(strcmp(ids, 'psychlvgl:XMLReference')), 3);
    plv_eq('a bad value', sum(strcmp(ids, 'psychlvgl:XMLValue')), 1);
    plv_eq('nothing else', numel(w), 8);
    plv_assert('every warning names the file', all(~cellfun(@isempty, strfind({w.msg}, 'unknown.xml'))));
    msgs = [w.msg];
    plv_assert('the warnings name what they skip', ...
               ~isempty(strfind(msgs, '<frobnicate>')) && ~isempty(strfind(msgs, '"wobble"')) && ...
               ~isempty(strfind(msgs, '<lv_frobnicator>')) && ~isempty(strfind(msgs, 'style_no_such_prop')) && ...
               ~isempty(strfind(msgs, '#no_such_const')) && ~isempty(strfind(msgs, 'no_such_subject')) && ...
               ~isempty(strfind(msgs, 'no_such_style')) && ~isempty(strfind(msgs, 'middle')));
    plv_eq('the rest of the file still loads', ...
           isfield(nu, {'u1', 'u2', 'u3', 'u4', 'u5', 'u6', 'f1'}), [true(1, 6) false]);
    plv_eq('an attribute with a dangling reference is dropped', PsychLVGL('LabelGetText', nu.u3), 'Text');
    plv_xml_collect('reset');
    PsychLVGLXMLToM(fullfile(fx, 'unknown.xml'), gen, opts);
    w2 = plv_xml_collect('get');
    plv_eq('PsychLVGLXMLToM reports the same warnings', {w2.id}, ids);

    % the default handler is warning()
    lastwarn('');
    s = warning();
    warning('off', 'psychlvgl:XMLUnknown');
    warning('off', 'backtrace');
    fprintf('   (four warnings expected here)\n');
    PsychLVGLLoadXML(fullfile(fx, 'unknown.xml'), PsychLVGL('ScreenCreate'));
    warning(s);
    [~, lid] = lastwarn();
    plv_assert('without Warn the problems go to warning()', any(strcmp(lid, {'psychlvgl:XMLReference', 'psychlvgl:XMLValue'})));

    % ----------------------------------------------------------- options
    plv_xml_collect('reset');
    o2 = opts;
    o2.Consts = struct('app_title', 'Override', 'card_w', 90);
    [~, n3] = PsychLVGLLoadXML(fullfile(fx, 'main.xml'), PsychLVGL('ScreenCreate'), o2);
    plv_eq('Consts replaces a constant', PsychLVGL('LabelGetText', n3.title), 'Override');
    layout();
    plv_eq('a numeric Consts value, through a chained constant', PsychLVGL('ObjGetWidth', n3.card), 90);

    plv_xml_collect('reset');
    o3 = opts;
    o3.AssetDir = tempdir;
    PsychLVGLLoadXML(fullfile(fx, 'main.xml'), PsychLVGL('ScreenCreate'), o3);
    w = plv_xml_collect('get');
    plv_eq('AssetDir moves the assets, and missing ones warn', ...
           sum(strcmp({w.id}, 'psychlvgl:XMLReference')), 2);

    [r4, n4] = PsychLVGLLoadXML(fullfile(fx, 'my_button.xml'), PsychLVGL('ScreenCreate'), opts);
    plv_assert('a component file makes one child of the parent', PsychLVGL('IsValid', r4));
    plv_eq('with its defaults', PsychLVGL('LabelGetText', n4.caption), 'Press');
    plv_eq('the child of the root', PsychLVGL('ObjGetParent', n4.caption), r4);

    plv_xml_collect('reset');
    PsychLVGLLoadXML(fullfile(fx, 'my_button.xml'), [], struct('Warn', @plv_xml_collect, 'Globals', 'none'));
    plv_eq('Globals none reads no globals.xml', numel(plv_xml_collect('get')), 0);

    plv_throws('a missing file', 'psychlvgl:XML', @() PsychLVGLLoadXML(fullfile(fx, 'none.xml')));
    plv_throws('an unknown option', 'psychlvgl:Usage', ...
               @() PsychLVGLLoadXML(fullfile(fx, 'main.xml'), [], struct('Color', 1)));
    plv_throws('a bad parent', 'psychlvgl:InvalidHandle', ...
               @() PsychLVGLLoadXML(fullfile(fx, 'main.xml'), 12345));
    plv_throws('a root element that is not a screen or component', 'psychlvgl:XML', ...
               @() PsychLVGLLoadXML(fullfile(fx, 'lvgl_examples', 'NOTICE.txt')));

    % ------------------------------------ the panel of PsychLVGLXMLDemo
    plv_xml_collect('reset');
    % The demo panel ships in examples/, not tests/, because the demo loads it
    % from a release package.
    demoXml = fullfile(fileparts(fileparts(fx)), 'examples', 'xml', 'gabor_panel', 'gabor_panel.xml');
    [~, nd] = PsychLVGLLoadXML(demoXml, PsychLVGL('ScreenCreate'), opts);
    w = plv_xml_collect('get');
    plv_eq('the demo panel loads without a warning', numel(w), 0);
    for k = 1:numel(w)
        fprintf(2, '        %s: %s\n', w(k).id, w(k).msg);
    end
    plv_eq('the demo tile shows the contrast subject through component props', ...
           PsychLVGL('LabelGetText', nd.value), '60 %');
    plv_eq('the demo arc follows the same subject', PsychLVGL('ArcGetValue', nd.contrast_arc), 60);

    % ------------------------------- examples copied from the LVGL tree
    ex = dir(fullfile(fx, 'lvgl_examples', 'lv_example_*.xml'));
    plv_assert('the LVGL examples are there', numel(ex) >= 8);
    for k = 1:numel(ex)
        plv_xml_collect('reset');
        try
            PsychLVGLLoadXML(fullfile(fx, 'lvgl_examples', ex(k).name), PsychLVGL('ScreenCreate'), opts);
            w = plv_xml_collect('get');
            plv_eq(sprintf('LVGL example %s loads cleanly', ex(k).name), numel(w), 0);
            for j = 1:numel(w)
                fprintf(2, '        %s: %s\n', w(j).id, w(j).msg);
            end
        catch err
            plv_assert(sprintf('LVGL example %s loads (%s)', ex(k).name, err.message), false);
        end
    end
end

function layout()
    persistent t
    if isempty(t); t = 100; end
    t = t + 0.05;
    PsychLVGL('Update', t, [0 0 0], 0, zeros(0, 2));
end

function delete_if(f)
    if exist(f, 'file')
        delete(f);
    end
end
