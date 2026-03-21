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
