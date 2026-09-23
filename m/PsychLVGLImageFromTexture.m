function img = PsychLVGLImageFromTexture(win, tex)
% PSYCHLVGLIMAGEFROMTEXTURE  An LVGL image that draws a Psychtoolbox texture.
%
%   img = PsychLVGLImageFromTexture(win, tex)
%
%   win   The onscreen window the texture belongs to.
%   tex   A Psychtoolbox texture handle. It must be a GL_TEXTURE_2D texture,
%         which Screen('MakeTexture') makes with specialFlags 1:
%
%             tex = Screen('MakeTexture', win, imageMatrix, [], 1);
%
%         Both storage orders work. The default textureOrientation stores the
%         matrix transposed; textureOrientation 1 or 2 stores it upright,
%         bottom row first. The image shows the same way for both: as
%         Screen('DrawTexture') shows it, imageMatrix columns wide and rows
%         high.
%
%   img   An image handle for PsychLVGL('ImageSetSrc', imageObject, img).
%
%   The NanoVG renderer samples the texture directly, so no pixel crosses
%   the CPU. This needs no OpenGL context of its own: call it outside
%   Screen('BeginOpenGL').
%
%   Rotation, scale, recolor and clip radius work as for any image. A texture
%   image does not tile.
%
%   The texture stays yours. Keep it open while an image object shows it,
%   and close it only after PsychLVGL('ImageSetSrc', obj, 0) and
%   PsychLVGL('ImageDelete', img). When you change the texture contents,
%   call PsychLVGL('ObjInvalidate', imageObject) so that LVGL draws the
%   image again.
%
%   Example:
%       tex = Screen('MakeTexture', win, imread('face.png'), [], 1);
%       img = PsychLVGLImageFromTexture(win, tex);
%       obj = PsychLVGL('ImageCreate', PsychLVGL('ScreenActive'));
%       PsychLVGL('ImageSetSrc', obj, img);
%
%   Errors: psychlvgl:Texture when the texture is a rectangle texture, the
%   Psychtoolbox default without specialFlags 1. LVGL's renderer samples
%   GL_TEXTURE_2D only.
%
%   See also PSYCHLVGLOPEN, PSYCHLVGLCLOSE.

    GL_TEXTURE_2D = 3553;

    if nargin ~= 2
        error('psychlvgl:Usage', 'Usage: img = PsychLVGLImageFromTexture(win, tex)');
    end

    [glTex, target] = Screen('GetOpenGLTexture', win, tex);
    if target ~= GL_TEXTURE_2D
        error('psychlvgl:Texture', ...
              ['texture %d is not a GL_TEXTURE_2D texture (target 0x%X). Make it ' ...
               'with specialFlags 1: Screen(''MakeTexture'', win, M, [], 1).'], ...
              tex, target);
    end

    % Psychtoolbox reports a texture's storage order nowhere but in how it
    % maps an image position to texture coordinates. The top left pixel of an
    % upright texture, stored bottom row first, maps to v near 1; that of a
    % texture made from a matrix, stored transposed, maps to v near 0.
    [~, ~, ~, v0] = Screen('GetOpenGLTexture', win, tex, 0, 0);
    transposed = v0 < 0.5;

    % Screen('Rect') is the size as shown, whatever the storage order.
    rect = Screen('Rect', tex);
    img = PsychLVGL('ImageFromTexture', glTex, rect(3) - rect(1), rect(4) - rect(2), ...
                    transposed);
end
