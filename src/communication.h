#define TAILLE_BUFF 100

#ifndef __COMMUNICATION_H
#define __COMMUNICATION_H

/**
 * Envoie un message en utilisant une socket
 * @param s : la socket
 * @param format : la chaine qu'on va enoyer
 * @return la taille de la chaine envoyée sur la socket
 */
int envoieMessage (int s, char *format, ...);

/**
 * Recoie un message en utilisant une socket
 * @param s : la socket
 * @param buff : buffeur sur lequel on va écrire
 * @return la taille de la chaine recupérée sur la socket
 */
int recoieMessage (int s, char* buff);

/**
 * Recoie des donnees utilisant une socket
 * @param fd : descripteur de fichier sur lequel on va ecrire
 * @param s : la socket
 * @return le nombre d'octets écris dans le fichier
 */
int RecoieDonnees (int fd, int s);

#endif
