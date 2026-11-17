package local.droidbridge.helper;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.Context;
import android.content.Intent;
import android.content.pm.ShortcutInfo;
import android.content.pm.ShortcutManager;
import android.os.Build;
import android.os.Bundle;
import android.util.Base64;
import java.nio.charset.StandardCharsets;

public final class Actions extends Activity {
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        String token = getIntent().getStringExtra("token");
        String action = getIntent().getStringExtra("action");
        if (token == null || !token.matches("[0-9a-fA-F-]{36}")) { finish(); return; }
        String verb;
        switch (action == null ? "" : action) {
            case "read": verb = "Передать текст из буфера Android на подключённый Mac?"; break;
            case "write": verb = "Заменить текст в буфере Android текстом с подключённого Mac?"; break;
            case "pin": verb = "Добавить ярлык приложения на главный экран?"; break;
            default: finish(); return;
        }
        new AlertDialog.Builder(this).setTitle("DroidBridge").setMessage(verb)
            .setNegativeButton("Отмена", (dialog, which) -> reply(token, "cancel", ""))
            .setPositiveButton("Продолжить", (dialog, which) -> getWindow().getDecorView().postDelayed(() -> perform(token, action), 220))
            .setOnCancelListener(dialog -> reply(token, "cancel", "")).show();
    }

    private void perform(String token, String action) {
        try {
            if (action.equals("pin")) {
                String name = getIntent().getStringExtra("package");
                if (name == null || !name.matches("[A-Za-z0-9_.]+") || getPackageManager().getLaunchIntentForPackage(name) == null) {
                    reply(token, "error", "У приложения нет доступного экрана запуска."); return;
                }
                if (Build.VERSION.SDK_INT < 26) { reply(token, "error", "Для закрепления ярлыка нужен Android 8 или новее."); return; }
                ShortcutManager manager = getSystemService(ShortcutManager.class);
                if (manager == null || !manager.isRequestPinShortcutSupported()) {
                    reply(token, "error", "Лаунчер не поддерживает закрепление ярлыков."); return;
                }
                CharSequence label = getPackageManager().getApplicationLabel(getPackageManager().getApplicationInfo(name, 0));
                Intent intent = new Intent(this, OpenShortcut.class).setAction(Intent.ACTION_VIEW).putExtra("package", name);
                ShortcutInfo shortcut = new ShortcutInfo.Builder(this, name).setShortLabel(label).setIntent(intent).build();
                if (!manager.requestPinShortcut(shortcut, null)) {
                    reply(token, "error", "Лаунчер отклонил запрос на создание ярлыка."); return;
                }
                reply(token, "ok", "");
                return;
            }
            ClipboardManager clipboard = (ClipboardManager) getSystemService(Context.CLIPBOARD_SERVICE);
            if (action.equals("write")) {
                String input = getIntent().getStringExtra("text");
                clipboard.setPrimaryClip(ClipData.newPlainText("DroidBridge", new String(Base64.decode(input, Base64.DEFAULT), StandardCharsets.UTF_8)));
                reply(token, "ok", "");
            } else {
                ClipData data = clipboard.getPrimaryClip();
                CharSequence value = data == null || data.getItemCount() == 0 ? null : data.getItemAt(0).getText();
                if (value == null) reply(token, "error", "В буфере Android нет обычного текста. Разблокируйте телефон и повторите.");
                else reply(token, "ok", value.toString());
            }
        } catch (Exception failure) {
            reply(token, "error", failure.getMessage() == null ? "Android отклонил операцию." : failure.getMessage());
        }
    }

    private void reply(String token, String state, String text) {
        String encoded = Base64.encodeToString(text.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
        getSharedPreferences("responses", 0).edit().putString(token, state + ":" + encoded).commit();
        finish();
    }
}
