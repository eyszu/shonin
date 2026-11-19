// Re-encodes a picked photo as a baseline JPEG (max 1600px) before upload.
// This sidesteps formats the server cannot decode (WebP, HEIC, progressive
// JPEG), applies EXIF rotation, and keeps phone-camera uploads small.
// The server still does the authoritative 192x192 resize.
export async function prepareImage(file, maxSide = 1600) {
  try {
    const bmp = await createImageBitmap(file, { imageOrientation: "from-image" });
    const scale = Math.min(1, maxSide / Math.max(bmp.width, bmp.height));
    const w = Math.max(1, Math.round(bmp.width * scale));
    const h = Math.max(1, Math.round(bmp.height * scale));
    const canvas = document.createElement("canvas");
    canvas.width = w; canvas.height = h;
    const ctx = canvas.getContext("2d");
    ctx.fillStyle = "#fff"; // JPEG has no transparency
    ctx.fillRect(0, 0, w, h);
    ctx.drawImage(bmp, 0, 0, w, h);
    bmp.close?.();
    const blob = await new Promise((res) => canvas.toBlob(res, "image/jpeg", 0.9));
    if (blob) return blob;
  } catch {}
  return file; // let the server try the original
}
