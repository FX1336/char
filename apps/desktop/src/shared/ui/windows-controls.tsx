import { getCurrentWebviewWindow } from "@tauri-apps/api/webviewWindow";
import { Minus, Square, X } from "lucide-react";
import { useEffect, useState } from "react";

import { cn } from "@hypr/utils";

export function WindowsControls() {
  const [isMaximized, setIsMaximized] = useState(false);

  useEffect(() => {
    const win = getCurrentWebviewWindow();
    win.isMaximized().then(setIsMaximized);

    const unlisten = win.onResized(() => {
      win.isMaximized().then(setIsMaximized);
    });

    return () => {
      unlisten.then((fn: () => void) => fn());
    };
  }, []);

  const onMinimize = () => getCurrentWebviewWindow().minimize();
  const onMaximize = () => getCurrentWebviewWindow().toggleMaximize();
  const onClose = () => getCurrentWebviewWindow().close();

  return (
    <div className="flex h-full items-stretch" data-tauri-drag-region="false">
      <button
        type="button"
        onClick={() => void onMinimize()}
        className={cn([
          "flex h-full w-11 items-center justify-center",
          "text-neutral-600 hover:bg-neutral-200",
          "transition-colors duration-100",
        ])}
      >
        <Minus size={12} strokeWidth={1.5} />
      </button>
      <button
        type="button"
        onClick={() => void onMaximize()}
        className={cn([
          "flex h-full w-11 items-center justify-center",
          "text-neutral-600 hover:bg-neutral-200",
          "transition-colors duration-100",
        ])}
      >
        {isMaximized
          ? (
            <RestoreIcon />
          )
          : (
            <Square size={11} strokeWidth={1.5} />
          )}
      </button>
      <button
        type="button"
        onClick={() => void onClose()}
        className={cn([
          "flex h-full w-11 items-center justify-center",
          "text-neutral-600 hover:bg-[#c42b1c] hover:text-white",
          "transition-colors duration-100",
        ])}
      >
        <X size={12} strokeWidth={1.5} />
      </button>
    </div>
  );
}

function RestoreIcon() {
  return (
    <svg
      width="11"
      height="11"
      viewBox="0 0 11 11"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.1"
    >
      <rect x="2" y="0.5" width="8.5" height="8.5" rx="0.5" />
      <path d="M0.5 2.5 v8 h8" />
    </svg>
  );
}
