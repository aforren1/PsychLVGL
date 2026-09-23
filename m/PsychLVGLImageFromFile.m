function img = PsychLVGLImageFromFile(path)
% PSYCHLVGLIMAGEFROMFILE  Image handle from a PNG, JPEG or other image file.
%   img = PsychLVGLImageFromFile(path) reads the file with imread and calls
%   PsychLVGL('ImageFromArray'). Transparency in the file is kept. The
%   result is an image handle for PsychLVGL('ImageSetSrc', imageObj, img);
%   PsychLVGL('ImageDelete', img) or Shutdown frees it.
%
%   PsychLVGLLoadXML and the files PsychLVGLXMLToM writes use it for the
%   images an XML user interface declares. The pixels are copied, and LVGL
%   uploads them again every time it draws the image; for a large or often
%   redrawn picture, make a Psychtoolbox texture and use
%   PsychLVGLImageFromTexture instead.

    if ~ischar(path) || isempty(path)
        error('psychlvgl:Usage', 'Usage: img = PsychLVGLImageFromFile(path)');
    end
    if exist(path, 'file') ~= 2
        error('psychlvgl:Usage', 'image file %s does not exist', path);
    end
    [pix, map, alpha] = imread(path);
    if ~isempty(map)
        % Indexed images: the map is 0 to 1 in both engines.
        pix = uint8(round(255 * ind2rgb(pix, map)));
    end
    pix = to_uint8(pix);
    if size(pix, 3) == 2
        % Grey plus alpha, as Octave returns some PNGs.
        alpha = pix(:, :, 2);
        pix = pix(:, :, 1);
    end
    if ~isempty(alpha)
        if size(pix, 3) == 1
            pix = repmat(pix, [1 1 3]);
        end
        pix = cat(3, pix(:, :, 1:3), to_uint8(alpha));
    end
    img = PsychLVGL('ImageFromArray', pix);
end

function x = to_uint8(x)
    switch class(x)
        case 'uint8'
        case 'uint16'
            x = uint8(bitshift(x, -8));
        case 'logical'
            x = uint8(x) * 255;
        otherwise
            x = uint8(round(255 * double(x)));
    end
end
