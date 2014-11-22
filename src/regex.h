#ifndef __REGEX_H
#define __REGEX_H

/**
 * Applique une expression reguliere a une chaine de caracteres.
 * @param expr : l'expression reguliere au format compatible perl
 * @param chaine : la chaine sur laquel appliquer l'expression
 * @return les differentes partie de la chaine sellectionnees par l'expression s'il l'expression ne correspond pas a  la chaine, le resultat est NULL
 */
gchar ** recup_match_chaine(const gchar *expr, const gchar *chaine);

#endif
