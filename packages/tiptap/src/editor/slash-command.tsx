import {
  autoUpdate,
  computePosition,
  flip,
  limitShift,
  offset,
  shift,
  type VirtualElement,
} from "@floating-ui/dom";
import { Extension } from "@tiptap/core";
import { PluginKey } from "@tiptap/pm/state";
import { ReactRenderer } from "@tiptap/react";
import Suggestion from "@tiptap/suggestion";
import {
  CheckSquareIcon,
  CodeIcon,
  Heading1Icon,
  Heading2Icon,
  Heading3Icon,
  ListIcon,
  ListOrderedIcon,
  QuoteIcon,
  TableIcon,
  TypeIcon,
} from "lucide-react";
import {
  forwardRef,
  useEffect,
  useImperativeHandle,
  useState,
} from "react";

import { cn } from "@hypr/utils";

interface SlashCommand {
  id: string;
  label: string;
  description: string;
  Icon: React.ComponentType<{ className?: string }>;
  execute: (editor: any) => void;
}

const COMMANDS: SlashCommand[] = [
  {
    id: "text",
    label: "Text",
    description: "Plain paragraph",
    Icon: TypeIcon,
    execute: (editor) =>
      editor.chain().focus().clearNodes().unsetAllMarks().run(),
  },
  {
    id: "h1",
    label: "Heading 1",
    description: "Large section heading",
    Icon: Heading1Icon,
    execute: (editor) =>
      editor.chain().focus().setHeading({ level: 1 }).run(),
  },
  {
    id: "h2",
    label: "Heading 2",
    description: "Medium section heading",
    Icon: Heading2Icon,
    execute: (editor) =>
      editor.chain().focus().setHeading({ level: 2 }).run(),
  },
  {
    id: "h3",
    label: "Heading 3",
    description: "Small section heading",
    Icon: Heading3Icon,
    execute: (editor) =>
      editor.chain().focus().setHeading({ level: 3 }).run(),
  },
  {
    id: "bullet",
    label: "Bullet List",
    description: "Unordered list",
    Icon: ListIcon,
    execute: (editor) => editor.chain().focus().toggleBulletList().run(),
  },
  {
    id: "ordered",
    label: "Numbered List",
    description: "Ordered list",
    Icon: ListOrderedIcon,
    execute: (editor) => editor.chain().focus().toggleOrderedList().run(),
  },
  {
    id: "todo",
    label: "To-do",
    description: "Checkable task list",
    Icon: CheckSquareIcon,
    execute: (editor) => editor.chain().focus().toggleTaskList().run(),
  },
  {
    id: "code",
    label: "Code Block",
    description: "Code with syntax highlighting",
    Icon: CodeIcon,
    execute: (editor) => editor.chain().focus().toggleCodeBlock().run(),
  },
  {
    id: "quote",
    label: "Quote",
    description: "Blockquote",
    Icon: QuoteIcon,
    execute: (editor) => editor.chain().focus().toggleBlockquote().run(),
  },
  {
    id: "table",
    label: "Table",
    description: "Insert a 3×3 table",
    Icon: TableIcon,
    execute: (editor) =>
      editor
        .chain()
        .focus()
        .insertTable({ rows: 3, cols: 3, withHeaderRow: true })
        .run(),
  },
];

function filterCommands(query: string): SlashCommand[] {
  if (!query) {
    return COMMANDS;
  }
  const q = query.toLowerCase();
  return COMMANDS.filter(
    (cmd) =>
      cmd.label.toLowerCase().includes(q) ||
      cmd.description.toLowerCase().includes(q) ||
      cmd.id.toLowerCase().includes(q),
  );
}

const SlashCommandList = forwardRef<
  { onKeyDown: (props: { event: KeyboardEvent }) => boolean },
  { items: SlashCommand[]; command: (item: SlashCommand) => void }
>((props, ref) => {
  const [selectedIndex, setSelectedIndex] = useState(0);

  useEffect(() => setSelectedIndex(0), [props.items]);

  const selectItem = (index: number) => {
    const item = props.items[index];
    if (item) {
      props.command(item);
    }
  };

  useImperativeHandle(ref, () => ({
    onKeyDown: ({ event }) => {
      if (props.items.length === 0) {
        return false;
      }

      if (["ArrowUp", "ArrowDown", "Enter"].includes(event.key)) {
        event.preventDefault();
      }

      switch (event.key) {
        case "ArrowUp":
          setSelectedIndex(
            (prev) => (prev + props.items.length - 1) % props.items.length,
          );
          return true;
        case "ArrowDown":
          setSelectedIndex((prev) => (prev + 1) % props.items.length);
          return true;
        case "Enter":
          selectItem(selectedIndex);
          return true;
        default:
          return false;
      }
    },
  }));

  if (props.items.length === 0) {
    return null;
  }

  return (
    <div className="mention-container">
      {props.items.map((item, index) => (
        <button
          key={item.id}
          className={cn([
            "mention-item",
            index === selectedIndex && "is-selected",
          ])}
          onClick={() => selectItem(index)}
        >
          <item.Icon className="mention-type-icon" />
          <div className="slash-command-text">
            <span className="mention-label">{item.label}</span>
            <span className="slash-command-description">
              {item.description}
            </span>
          </div>
        </button>
      ))}
    </div>
  );
});

SlashCommandList.displayName = "SlashCommandList";

const slashPluginKey = new PluginKey("slash-command");

export const SlashCommand = Extension.create({
  name: "slashCommand",

  addProseMirrorPlugins() {
    return [
      Suggestion({
        editor: this.editor,
        char: "/",
        pluginKey: slashPluginKey,
        allowSpaces: false,
        startOfLine: false,
        command: ({ editor, range, props }) => {
          const cmd = props as SlashCommand;
          editor.chain().focus().deleteRange(range).run();
          cmd.execute(editor);
        },
        items: ({ query }) => filterCommands(query),
        render: () => {
          let renderer: ReactRenderer;
          let cleanup: (() => void) | undefined;
          let floatingEl: HTMLElement;
          let referenceEl: VirtualElement;

          const updatePosition = () => {
            void computePosition(referenceEl, floatingEl, {
              placement: "bottom-start",
              middleware: [
                offset(4),
                flip(),
                shift({ limiter: limitShift() }),
              ],
            }).then(({ x, y }) => {
              Object.assign(floatingEl.style, {
                left: `${x}px`,
                top: `${y}px`,
              });
            });
          };

          return {
            onStart: (props) => {
              renderer = new ReactRenderer(SlashCommandList, {
                props,
                editor: props.editor,
              });

              floatingEl = renderer.element as HTMLElement;
              Object.assign(floatingEl.style, {
                position: "absolute",
                top: "0",
                left: "0",
                zIndex: "9999",
              });
              document.body.appendChild(floatingEl);

              if (!props.clientRect) {
                return;
              }

              referenceEl = {
                getBoundingClientRect: () =>
                  props.clientRect?.() ?? new DOMRect(),
              };

              cleanup = autoUpdate(referenceEl, floatingEl, updatePosition);
              updatePosition();
            },

            onUpdate: (props) => {
              renderer.updateProps(props);
              if (props.clientRect) {
                referenceEl.getBoundingClientRect = () =>
                  props.clientRect?.() ?? new DOMRect();
              }
              updatePosition();
            },

            onKeyDown: (props) => {
              if (props.event.key === "Escape") {
                cleanup?.();
                floatingEl?.remove();
                return true;
              }
              // @ts-ignore
              return renderer.ref?.onKeyDown(props) ?? false;
            },

            onExit: () => {
              cleanup?.();
              floatingEl?.remove();
              renderer?.destroy();
            },
          };
        },
      }),
    ];
  },
});
