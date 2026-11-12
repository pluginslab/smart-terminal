package com.termux.terminal;

import java.util.UUID;

/**
 * A terminal session: an emulator coupled to a {@link Transport} (an SSH channel in Smart Terminal).
 * <p>
 * Changed from Termux: no local process. Output from the remote side arrives through
 * {@link #feed(byte[], int)}, which must be called on the main thread; input typed into the
 * view goes to {@link Transport#write(byte[], int, int)}; size changes go to
 * {@link Transport#resize(int, int)}. All emulation and callbacks run on the main thread.
 */
public final class TerminalSession extends TerminalOutput {

    /** Where the session's bytes go, and where its size is reported. */
    public interface Transport {
        /** Called on the main thread; must not block. */
        void write(byte[] data, int offset, int count);
        /** The view's size in cells, on first layout and on every change after. */
        void resize(int columns, int rows);
    }

    public final String mHandle = UUID.randomUUID().toString();

    TerminalEmulator mEmulator;

    /** Buffer to translate code points into UTF-8 before writing. */
    private final byte[] mUtf8InputBuffer = new byte[5];

    TerminalSessionClient mClient;

    private final Transport mTransport;
    private final Integer mTranscriptRows;
    private boolean mRunning = true;

    /** Set by the application for user identification of session, not by terminal. */
    public String mSessionName;

    public TerminalSession(Transport transport, Integer transcriptRows, TerminalSessionClient client) {
        this.mTransport = transport;
        this.mTranscriptRows = transcriptRows;
        this.mClient = client;
    }

    public void updateTerminalSessionClient(TerminalSessionClient client) {
        mClient = client;
        if (mEmulator != null) mEmulator.updateTerminalSessionClient(client);
    }

    /** Resize (or create) the emulator and tell the remote side. */
    public void updateSize(int columns, int rows, int cellWidthPixels, int cellHeightPixels) {
        if (mEmulator == null) {
            mEmulator = new TerminalEmulator(this, columns, rows, cellWidthPixels, cellHeightPixels, mTranscriptRows, mClient);
        } else {
            mEmulator.resize(columns, rows, cellWidthPixels, cellHeightPixels);
        }
        mTransport.resize(columns, rows);
    }

    /** Current size in cells, or null before the first layout. */
    public int[] getSize() {
        return mEmulator == null ? null : new int[]{mEmulator.mColumns, mEmulator.mRows};
    }

    /** Bytes from the remote side. Main thread only. */
    public void feed(byte[] data, int length) {
        if (mEmulator == null) return;
        mEmulator.append(data, length);
        notifyScreenUpdate();
    }

    /** The remote side ended. Main thread only. */
    public void markFinished() {
        if (!mRunning) return;
        mRunning = false;
        mClient.onSessionFinished(this);
    }

    public String getTitle() {
        return (mEmulator == null) ? null : mEmulator.getTitle();
    }

    @Override
    public void write(byte[] data, int offset, int count) {
        if (mRunning) mTransport.write(data, offset, count);
    }

    /** Write the Unicode code point to the terminal encoded in UTF-8. */
    public void writeCodePoint(boolean prependEscape, int codePoint) {
        if (codePoint > 1114111 || (codePoint >= 0xD800 && codePoint <= 0xDFFF)) {
            throw new IllegalArgumentException("Invalid code point: " + codePoint);
        }
        int p = 0;
        if (prependEscape) mUtf8InputBuffer[p++] = 27;
        if (codePoint <= 0b1111111) {
            mUtf8InputBuffer[p++] = (byte) codePoint;
        } else if (codePoint <= 0b11111111111) {
            mUtf8InputBuffer[p++] = (byte) (0b11000000 | (codePoint >> 6));
            mUtf8InputBuffer[p++] = (byte) (0b10000000 | (codePoint & 0b111111));
        } else if (codePoint <= 0b1111111111111111) {
            mUtf8InputBuffer[p++] = (byte) (0b11100000 | (codePoint >> 12));
            mUtf8InputBuffer[p++] = (byte) (0b10000000 | ((codePoint >> 6) & 0b111111));
            mUtf8InputBuffer[p++] = (byte) (0b10000000 | (codePoint & 0b111111));
        } else {
            mUtf8InputBuffer[p++] = (byte) (0b11110000 | (codePoint >> 18));
            mUtf8InputBuffer[p++] = (byte) (0b10000000 | ((codePoint >> 12) & 0b111111));
            mUtf8InputBuffer[p++] = (byte) (0b10000000 | ((codePoint >> 6) & 0b111111));
            mUtf8InputBuffer[p++] = (byte) (0b10000000 | (codePoint & 0b111111));
        }
        write(mUtf8InputBuffer, 0, p);
    }

    public TerminalEmulator getEmulator() {
        return mEmulator;
    }

    protected void notifyScreenUpdate() {
        mClient.onTextChanged(this);
    }

    public void reset() {
        mEmulator.reset();
        notifyScreenUpdate();
    }

    public synchronized boolean isRunning() {
        return mRunning;
    }

    @Override
    public void titleChanged(String oldTitle, String newTitle) {
        mClient.onTitleChanged(this);
    }

    @Override
    public void onCopyTextToClipboard(String text) {
        mClient.onCopyTextToClipboard(this, text);
    }

    @Override
    public void onPasteTextFromClipboard() {
        mClient.onPasteTextFromClipboard(this);
    }

    @Override
    public void onBell() {
        mClient.onBell(this);
    }

    @Override
    public void onColorsChanged() {
        mClient.onColorsChanged(this);
    }
}
