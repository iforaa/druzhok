export type ReplyPayload = {
  text?: string;
  mediaUrl?: string;
  mediaUrls?: string[];
  isReasoning?: boolean;
  isError?: boolean;
  isSilent?: boolean;
  replyToId?: number;
  audioAsVoice?: boolean;
};

export type InboundContext = {
  body: string;
  from: string;
  chatId: string;
  chatType: "direct" | "group";
  senderId: string;
  senderName: string;
  messageId: number;
  replyTo?: ReplyContext;
  media?: MediaRef[];
  sessionKey: string;
  timestamp: number;
};

export type ReplyContext = {
  messageId: number;
  senderId: string;
  senderName: string;
  body: string;
};

export type MediaRef = {
  path: string;
  contentType: string;
  filename?: string;
};

export type DeliveryResult = {
  delivered: boolean;
  messageId?: number;
  error?: string;
};

export type DraftStreamOpts = {
  replyToMessageId?: number;
  threadId?: number;
  minInitialChars?: number;
};

export interface DraftStream {
  update(text: string): void;
  materialize(): Promise<number>;
  forceNewMessage(): void;
  stop(): Promise<void>;
  flush(): Promise<void>;
  messageId(): number | undefined;
}

export interface Channel {
  start(): Promise<void>;
  stop(): Promise<void>;
  onMessage: (ctx: InboundContext) => Promise<void>;
  sendMessage(chatId: string, payload: ReplyPayload): Promise<DeliveryResult>;
  editMessage(chatId: string, messageId: number, payload: ReplyPayload): Promise<void>;
  deleteMessage(chatId: string, messageId: number): Promise<void>;
  createDraftStream(chatId: string, opts: DraftStreamOpts): DraftStream;
  sendTyping(chatId: string): Promise<void>;
  setReaction(chatId: string, messageId: number, emoji: string): Promise<void>;
}
