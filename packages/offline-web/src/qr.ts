import QRCode from "qrcode";
import jsQR from "jsqr";

export async function qrDataUrl(
  text: string,
  opts?: { width?: number },
): Promise<string> {
  return QRCode.toDataURL(text, {
    errorCorrectionLevel: "L",
    margin: 1,
    width: opts?.width ?? 280,
    color: { dark: "#0c0e0c", light: "#e8efe6" },
  });
}

export async function qrDataUrlFromBytes(
  bytes: Uint8Array,
  opts?: { width?: number },
): Promise<string> {
  // Binary optical frames: encode as ISO-8859-1 string for byte-preserving QR.
  let s = "";
  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
  return QRCode.toDataURL(s, {
    errorCorrectionLevel: "M",
    margin: 1,
    width: opts?.width ?? 320,
    color: { dark: "#0c0e0c", light: "#e8efe6" },
  });
}

export function decodeQrFromImageData(image: ImageData): Uint8Array | string | null {
  const result = jsQR(image.data, image.width, image.height, {
    inversionAttempts: "dontInvert",
  });
  if (!result) return null;
  // Prefer binary if present
  const bytes = result.binaryData;
  if (bytes && bytes.length) return new Uint8Array(bytes);
  return result.data;
}
