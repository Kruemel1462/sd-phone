import { useState } from 'react';
import type { ReactNode } from 'react';

import { device } from '@device';
import { AlertDialog } from '@/ui/AlertDialog';
import { requestOpenMail, requestOpenMessages } from '@/shell/deeplink';
import { fetchNui, isFiveM } from '@/core/nui';
import { t } from '@/i18n';

export function useContactActions(): {
    message: (number: string, isSelf?: boolean) => void;
    call:    (number: string, isSelf?: boolean) => void;
    email:   (address: string, isSelf?: boolean) => void;
    dialog:  ReactNode;
} {
    // Nur noch der Hinweis-Dialog. Die Rueckfrage vor dem Anruf ist entfernt, `call` waehlt
    // direkt - deshalb kennt der Zustand die Variante 'confirm' nicht mehr.
    const [dlg, setDlg] = useState<
        | { kind: 'notice'; title: string; message: string }
        | null
    >(null);

    function message(number: string, isSelf?: boolean) {
        if (isSelf) { setDlg({ kind: 'notice', title: t('classifieds.cantMessage', "Can't Message"), message: t('classifieds.cantMessageSelf', "You can't message yourself.") }); return; }
        const digits = (number ?? '').replace(/\D/g, '');
        if (digits) requestOpenMessages({ number: digits });
    }

    function call(number: string, isSelf?: boolean) {
        if (isSelf) { setDlg({ kind: 'notice', title: t('classifieds.cantCall', "Can't Call"), message: t('classifieds.cantCallSelf', "You can't call yourself.") }); return; }
        const digits = (number ?? '').replace(/\D/g, '');
        if (digits && isFiveM && device.calls) void fetchNui('sd-phone:call:dial', { number: digits });
    }

    function email(address: string, isSelf?: boolean) {
        if (isSelf) { setDlg({ kind: 'notice', title: t('classifieds.cantEmail', "Can't Email"), message: t('classifieds.cantEmailSelf', "You can't email yourself.") }); return; }
        const to = (address ?? '').trim();
        if (to) requestOpenMail({ to });
    }

    let dialog: ReactNode = null;
    if (dlg?.kind === 'notice') {
        dialog = (
            <AlertDialog
                title={dlg.title}
                message={dlg.message}
                confirmLabel={t('classifieds.ok', 'OK')}
                hideCancel
                onCancel={() => setDlg(null)}
                onConfirm={() => setDlg(null)}
            />
        );
    }

    return { message, call, email, dialog };
}
