// All viewports the report will be captured in.
// "device" entries use Playwright's built-in device presets (real UA, touch, DPR).
// "custom" entries are plain viewport sizes for laptop/desktop (no touch, DPR 1-2).
//
// Edit this list to add/remove breakpoints — nothing else needs to change.
export const VIEWPORTS = [
  { id: "iphone-se", kind: "device", device: "iPhone SE" },
  { id: "iphone-14", kind: "device", device: "iPhone 13" }, // Playwright has no "iPhone 14" preset; 13/14 share size
  { id: "iphone-15-pro-max", kind: "device", device: "iPhone 14 Pro Max" },
  { id: "ipad-mini", kind: "device", device: "iPad Mini" },
  { id: "ipad-pro-11", kind: "device", device: "iPad Pro 11" },
  { id: "laptop-1366", kind: "custom", width: 1366, height: 768, deviceScaleFactor: 1 },
  { id: "desktop-1920", kind: "custom", width: 1920, height: 1080, deviceScaleFactor: 1 },
  { id: "desktop-2560", kind: "custom", width: 2560, height: 1440, deviceScaleFactor: 1 },
];
