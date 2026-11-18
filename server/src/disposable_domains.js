// Throwaway e-mail providers refused at signup (BLOCK_DISPOSABLE_EMAIL=0
// turns this off). Add more with DISPOSABLE_DOMAINS_FILE: one domain per line.
import { readFileSync } from 'node:fs';

const BUILT_IN = `
0-mail.com 10minutemail.com 10minutemail.net 10minutemail.co.uk 20minutemail.com 33mail.com
anonbox.net anonymbox.com binkmail.com bobmail.info burnermail.io byom.de chacuo.net
crazymailing.com deadaddress.com discard.email discardmail.com discardmail.de disposableaddress.com
disposableemailaddresses.com dispostable.com dodgit.com dropmail.me e4ward.com emailondeck.com
emailsensei.com emailtemporanea.com emailtemporanea.net emailtemporario.com.br emailwarden.com
emltmp.com ephemail.net fakeinbox.com fakemail.net fakemailgenerator.com filzmail.com
getairmail.com getnada.com gishpuppy.com guerrillamail.biz guerrillamail.com guerrillamail.de
guerrillamail.info guerrillamail.net guerrillamail.org guerrillamailblock.com harakirimail.com
hidemail.de incognitomail.org inboxbear.com inboxkitten.com jetable.org kasmail.com
killmail.net klzlk.com linshiyouxiang.net mail-temp.com mail.tm mail7.io mailcatch.com
maildrop.cc mailexpire.com mailforspam.com mailinator.com mailinator.net mailinator2.com
mailnesia.com mailnull.com mailpoof.com mailsac.com mailtemp.info mailtothis.com
meltmail.com minuteinbox.com moakt.com mohmal.com mt2015.com mytemp.email mytrashmail.com
nada.email nwldx.com objectmail.com onetimemail.org opayq.com pokemail.net proxymail.eu
rcpt.at rmqkr.net sharklasers.com shieldemail.com sogetthis.com spam4.me spamavert.com
spambog.com spambox.us spamex.com spamfree24.org spamgourmet.com spamherelots.com spamhole.com
spaml.de spammotel.com spamspot.com tafmail.com temp-mail.io temp-mail.org tempail.com
tempemail.net tempinbox.com tempmail.dev tempmail.net tempmail.plus tempmailo.com tempr.email
tempsky.com throwam.com throwawaymail.com tmail.ws tmailinator.com tmpmail.net tmpmail.org
trash-mail.com trashmail.com trashmail.de trashmail.io trashmail.me trashmail.net trashmailer.com
trbvm.com veryrealemail.com wegwerfmail.de wegwerfmail.net wegwerfmail.org yepmail.net
yopmail.com yopmail.fr yopmail.net zetmail.com
`;

function load() {
  const domains = new Set(BUILT_IN.split(/\s+/).filter(Boolean));
  const file = process.env.DISPOSABLE_DOMAINS_FILE;
  if (file) {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const d = line.trim().toLowerCase();
      if (d && !d.startsWith('#')) domains.add(d);
    }
  }
  return domains;
}

export const DISPOSABLE_DOMAINS = load();
